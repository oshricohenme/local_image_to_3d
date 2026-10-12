import Foundation
import GRDB

public struct LiftConfig: Sendable {
    /// `<workdir>/` from spec §3: lift.sqlite, recipes/, models/, jobs/.
    public var workdir: URL
    /// The folder that contains the `lift_worker` package (`python/lift_worker/src` in this repo; the app bundle later).
    public var workerRuntime: URL
    /// The recipes built into the app: this repo's `dev-recipes/` (recipes + `shared/`). Copied to
    /// `<workdir>/recipes/bundled/` on open; only read here.
    public var bundledRecipes: URL
    public var runner: any CommandRunner
    public var toolSearchDirs: [String]?
    public var homebrewPrefix: String
    public var rosettaPrefix: String
    public var housekeepingInterval: Duration
    public var heartbeatSeconds: Double
    public var systemFree: @Sendable () -> Int
    /// This Mac's physical RAM in bytes (the memory warning and the default budget).
    public var physicalMemory: Int
    /// Plan 2 replaces this with the Keychain.
    public var hfToken: @Sendable () -> String?
    /// The shared Hugging Face cache `hf download` writes to and verification reads.
    public var hfHub: URL
    /// Weight file lists (the Hugging Face API by default; a fake in tests).
    public var weightsMetadata: any WeightsMetadata
    /// How long a failed or unknown weights check waits before a waiting job triggers another.
    public var weightsRecheckInterval: Duration
    /// Where `models_readme` fetches READMEs before a model is installed (a fake in tests).
    public var readmeHTTP: any ReadmeHTTP
    /// Waits between download retries (tests record it instead).
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(workdir: URL, workerRuntime: URL, bundledRecipes: URL, runner: any CommandRunner = SubprocessRunner(),
                toolSearchDirs: [String]? = nil, homebrewPrefix: String = "/opt/homebrew", rosettaPrefix: String = "/usr/local",
                housekeepingInterval: Duration = .seconds(15), heartbeatSeconds: Double = 2,
                systemFree: @escaping @Sendable () -> Int = Memory.systemFree, physicalMemory: Int = Memory.physical,
                hfToken: @escaping @Sendable () -> String? = { ProcessInfo.processInfo.environment["HF_TOKEN"] },
                hfHub: URL = HFHubAPI.defaultCache, weightsMetadata: (any WeightsMetadata)? = nil,
                weightsRecheckInterval: Duration = .seconds(30), readmeHTTP: any ReadmeHTTP = URLSessionReadmeHTTP(),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.workdir = workdir
        self.workerRuntime = workerRuntime
        self.bundledRecipes = bundledRecipes
        self.runner = runner
        self.toolSearchDirs = toolSearchDirs
        self.homebrewPrefix = homebrewPrefix
        self.rosettaPrefix = rosettaPrefix
        self.housekeepingInterval = housekeepingInterval
        self.heartbeatSeconds = heartbeatSeconds
        self.systemFree = systemFree
        self.physicalMemory = physicalMemory
        self.hfToken = hfToken
        self.hfHub = hfHub
        self.weightsMetadata = weightsMetadata ?? HFHubAPI(token: hfToken)
        self.weightsRecheckInterval = weightsRecheckInterval
        self.readmeHTTP = readmeHTTP
        self.sleep = sleep
    }
}

/// The step a worker is running (or will run once it's ready).
struct Assignment {
    var jobId: String
    var step: Int
    var task: String
    var keyValues: String
    var claim: Int
    var sent = false
    var startFootprint = 0
    var peak = 0
}

/// A live worker process, owned by the `Lift` actor.
final class WorkerHandle {
    let id: String
    let recipe: Recipe
    let process: WorkerProcess
    var pid: Int32 = 0
    var ready = false
    /// Shut down or killed on purpose: its exit is not a crash.
    var stopping = false
    /// One job per worker process (spec §8), so a job can always be killed with its worker.
    var job: Assignment?
    /// Model load cost: the estimate until ready, then the footprint measured at ready.
    var baseline: Int
    var lastFootprint = 0
    var idleSince: ContinuousClock.Instant?
    var loadError: String?
    let tail = Tail(limit: 40)

    init(id: String, recipe: Recipe, process: WorkerProcess, baseline: Int) {
        self.id = id
        self.recipe = recipe
        self.process = process
        self.baseline = baseline
    }

    var available: Bool { !stopping && job == nil }
    var reserved: Int { max(lastFootprint, baseline + (job?.claim ?? 0)) }
}

/// LiftCore's engine: store, catalog, installs, workers and the scheduler loop. Commands (Commands/*.swift)
/// are its public API; UI, HTTP and MCP call only those.
public actor Lift {
    public nonisolated let config: LiftConfig
    public nonisolated let store: Store
    let toolchain: Toolchain
    var tools: ToolPaths
    var settings: Settings
    var catalog = Catalog()
    /// Installed recipes, read from each model's own copy.
    var installed: [String: Recipe] = [:]
    var installing: [String: Task<Void, Never>] = [:]
    /// What an install or download is doing now: getting the code, setting up python, checking the install,
    /// downloading weights, verifying weights, cancelling.
    var phases: [String: String] = [:]
    /// Every download record (mirrors the `download` table), and the task of each one running.
    var downloads: [String: Download] = [:]
    var downloadTasks: [String: Task<Void, Never>] = [:]
    /// The last bundled-recipes sync (first launch or app update).
    var bundleSync = BundledRecipes.Result(copied: false, keptLocal: [])
    var weightReports: [String: WeightsReport] = [:]
    var verifying: Set<String> = []
    /// Recipes whose weights passed a check since their last worker start (spec §6: before every start).
    var verifiedForStart: Set<String> = []
    var lastVerify: [String: ContinuousClock.Instant] = [:]
    /// Recipes with a tick scheduled for when their recheck interval ends.
    var recheckScheduled: Set<String> = []
    var workers: [String: WorkerHandle] = [:]
    var logs: [String: LogFile] = [:]
    var housekeeping: Task<Void, Never>?
    /// A job waits for memory: heartbeats and housekeeping re-run the scheduler, so it starts once memory frees up.
    var waitingForMemory = false
    var closing = false

    var jobsDir: URL { config.workdir.appending(path: "jobs") }
    var recipesDir: URL { config.workdir.appending(path: "recipes") }

    var installer: Installer {
        Installer(runner: config.runner, models: config.workdir.appending(path: "models"), workerRuntime: config.workerRuntime,
                  tools: tools, toolEnvironment: toolchain.environment, hfToken: config.hfToken, hfHub: config.hfHub)
    }

    var verifier: WeightsVerifier { WeightsVerifier(metadata: config.weightsMetadata, hub: config.hfHub, store: store) }
    var bundled: BundledRecipes { BundledRecipes(bundle: config.bundledRecipes, recipes: recipesDir) }

    /// Opens the workdir, copies or refreshes the bundled recipes, marks jobs left loading/running as
    /// interrupted, detects the toolchain, scans recipes and starts scheduling. Nothing is cloned or downloaded.
    public static func open(_ config: LiftConfig) async throws -> Lift {
        let lift = try Lift(config: config)
        await lift.start()
        return lift
    }

    init(config: LiftConfig) throws {
        self.config = config
        try FileManager.default.createDirectory(at: config.workdir, withIntermediateDirectories: true)
        store = try Store(path: config.workdir.appending(path: "lift.sqlite").path)
        toolchain = Toolchain(runner: config.runner, searchDirs: config.toolSearchDirs,
                              homebrewPrefix: config.homebrewPrefix, rosettaPrefix: config.rosettaPrefix)
        tools = ToolPaths()
        settings = try store.db.read { try Settings.load($0) }
        if try store.db.read({ try SettingRecord.fetchOne($0, key: "memory_budget_gb") }) == nil {
            // First open (spec §8): min(48, 75% of this Mac's RAM), whole GB; the user can change it.
            settings.memoryBudgetGB = max(1, min(48, (0.75 * Double(config.physicalMemory) / 1e9).rounded(.down)))
            let s = settings
            try store.db.write { try s.save($0) }
        }
        try store.db.write { try Self.recoverInterrupted($0) }
        try store.db.write { try Self.recoverDownloads($0) }
        downloads = Dictionary(uniqueKeysWithValues: try store.db.read { try Download.fetchAll($0) }.map { ($0.id, $0) })
        bundleSync = try BundledRecipes(bundle: config.bundledRecipes, recipes: config.workdir.appending(path: "recipes")).sync()
    }

    func start() async {
        tools = await toolchain.detect()
        rescan()
        pumpDownloads()  // the ones a quit cut short, again
        // Exports cut short by a quit or crash run again (their steps already succeeded).
        for job in (try? await store.db.read { try JobRecord.filter(Column("exportPending") == true).fetchAll($0) }) ?? [] {
            if let spec = job.export { Task { try? await self.export(job.id, spec) } }
        }
        let interval = config.housekeepingInterval
        housekeeping = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await self?.housekeep()
            }
        }
        tick()
    }

    /// Stops all workers. Jobs still running stay `running` in the database and become
    /// `interrupted` on the next open (spec §7).
    public func close() {
        closing = true
        housekeeping?.cancel()
        for task in downloadTasks.values { task.cancel() }  // their state stays "downloading", resumed at the next open
        downloadTasks = [:]
        for w in workers.values {
            w.stopping = true
            w.process.kill()
        }
    }

    static func recoverInterrupted(_ db: Database) throws {
        let now = Date()
        let ids = try String.fetchAll(db, sql: "SELECT id FROM job WHERE state IN ('loading', 'running')")
        try db.execute(sql: "UPDATE step SET state = 'interrupted', workerId = NULL WHERE state IN ('loading', 'running')")
        try db.execute(sql: "UPDATE job SET state = 'interrupted', updatedAt = ? WHERE state IN ('loading', 'running')", arguments: [now])
        for id in ids {
            var e = EventRecord(id: nil, jobId: id, stepIdx: nil, at: now, kind: "state", detail: "interrupted")
            try e.insert(db)
        }
        try db.execute(sql: "UPDATE worker SET endedAt = ?, endReason = 'app_restart' WHERE endedAt IS NULL", arguments: [now])
    }

    // MARK: recipes and models

    /// `bundled-local` (your edited bundled recipes) first, then `bundled`. Recipes are the only entry point:
    /// there are no other sources (spec §4).
    var sourceDirs: [RecipeSourceDir] {
        let b = bundled
        var out: [RecipeSourceDir] = []
        if FileManager.default.fileExists(atPath: b.localDir.path) {
            let localShared = b.localDir.appending(path: "shared")
            out.append(RecipeSourceDir(name: "bundled-local", dir: b.localDir,
                                       shared: FileManager.default.fileExists(atPath: localShared.path) ? localShared : b.copyDir.appending(path: "shared")))
        }
        out.append(RecipeSourceDir(name: "bundled", dir: b.copyDir))
        return out
    }

    var developerMode: Bool { settings.devRecipes || ProcessInfo.processInfo.environment["LIFT_DEV_RECIPES"] == "1" }

    func rescan() {
        catalog = Catalog.scan(sourceDirs, includeDeveloper: developerMode)
        let models = config.workdir.appending(path: "models")
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: models.path)) ?? []
        installed = Dictionary(uniqueKeysWithValues: ids.compactMap { id in installer.installedRecipe(id).map { (id, $0) } })
    }

    func status(_ id: String) -> ModelStatus {
        if installing[id] != nil { return .installing(phase: phases[id] ?? "installing") }
        if let phase = phases[id] { return .installing(phase: phase) }  // checking the files after a download
        if let d = currentDownload(id), d.state.isActive {
            return .installing(phase: d.state == .queued ? "waiting to download" : d.state == .paused ? "download paused" : "downloading weights")
        }
        let base = installer.status(id: id, source: catalog.entries[id], pin: settings.pinOverrides[id])
        switch (base, weightReports[id]?.state) {
        case (.installed, .missing?), (.updateAvailable, .missing?): return .weightsMissing(weightReports[id]!.problems)
        case (.installed, .corrupt?), (.updateAvailable, .corrupt?): return .weightsCorrupt(weightReports[id]!.problems)
        default: return base
        }
    }

    /// The recipe a job step is validated and run against: the installed copy, else the source.
    func recipe(_ id: String) -> Recipe? { installed[id] ?? catalog.entries[id]?.recipe }

    func readiness(_ id: String) -> ModelReadiness {
        switch status(id) {
        case .installing: .installing
        case .installed, .updateAvailable, .weightsMissing, .weightsCorrupt: installed[id] == nil ? .notInstalled : .ready
        case .unsupported: .unsupported
        case .notInstalled, .installFailed: .notInstalled
        }
    }

    func saveSettings(_ new: Settings) throws {
        try store.db.write { try new.save($0) }
        settings = new
    }

    // MARK: scheduling

    /// Runs on every state change (spec §8).
    func tick() {
        guard !closing else { return }
        do {
            let pending = try store.db.read { db -> [(JobRecord, StepRecord)] in
                try JobRecord.filter([JobState.queued.rawValue, JobState.waiting.rawValue].contains(Column("state"))).fetchAll(db)
                    .compactMap { job in try StepRecord.fetchOne(db, key: ["jobId": job.id, "idx": job.currentStep]).map { (job, $0) } }
            }
            let recipes = pending.map { recipe($0.1.recipe) }
            let needs = try store.db.read { db in
                try zip(pending, recipes).map { pair, recipe in
                    try recipe.map { try Estimates.need(db, recipe: $0, task: pair.1.task, settings: pair.1.settings) } ?? MemoryNeed(load: 0, job: 0)
                }
            }
            var candidates: [Candidate] = []
            for (i, (job, step)) in pending.enumerated() {
                var model = recipes[i] == nil ? ModelReadiness.notInstalled : readiness(step.recipe)
                if model == .ready, let r = installed[step.recipe], needsVerifiedStart(r) {
                    model = .weightsUnverified
                    requestVerify(r)
                }
                candidates.append(Candidate(jobId: job.id, recipe: step.recipe, priority: job.priority, position: job.position,
                                            createdAt: job.createdAt, forceStart: job.forceStart, model: model, need: needs[i],
                                            memoryAccepted: job.memoryAccepted))
            }
            let input = SchedulerInput(
                candidates: candidates,
                workers: workers.values.map { WorkerSnapshot(recipe: $0.recipe.id, freeCapacity: $0.available ? 1 : 0, reserved: $0.reserved) },
                runningSteps: workers.values.filter { $0.job != nil }.count,
                maxSlots: settings.maxSlots, budget: settings.memoryBudgetBytes, systemFree: config.systemFree(),
                physical: config.physicalMemory, paused: settings.queuePaused)
            let byId = Dictionary(uniqueKeysWithValues: pending.map { ($0.0.id, $0) })
            let decisions = Scheduler.decide(input)
            for decision in decisions {
                switch decision {
                case .wait(let id, let reason):
                    guard let (job, step) = byId[id], job.state != .waiting || job.waitReason != reason else { continue }
                    _ = try store.db.write { db in try self.setState(db, job: job, step: step, .waiting, reason: reason) }
                case .start(let id):
                    if let (job, step) = byId[id] { try startStep(job: job, step: step) }
                }
            }
            // Steps that just started took their workers, so only truly idle ones are left to unload.
            let keep = Scheduler.keepLoaded(input, decisions)
            waitingForMemory = keep != nil
            if let keep {
                for w in workers.values where w.available && !keep.contains(w.recipe.id) { stop(w) }
            }
        } catch {
            print("lift: scheduler tick failed: \(error)")
        }
    }

    @discardableResult
    func setState(_ db: Database, job: JobRecord, step: StepRecord?, _ state: JobState, reason: WaitReason? = nil, error: String? = nil) throws -> JobRecord {
        let now = Date()
        var job = job
        job.state = state
        job.waitReason = reason
        job.updatedAt = now
        if let error { job.error = error }
        if state.isTerminal { job.finishedAt = now }
        try job.update(db)
        if var step {
            step.state = state
            step.waitReason = reason
            if let error { step.error = error }
            if state.isTerminal { step.finishedAt = now }
            try step.update(db)
        }
        var detail = state.rawValue
        if let reason, let data = try? JSONEncoder().encode(reason) { detail += " " + String(decoding: data, as: UTF8.self) }
        if let error { detail += ": " + error }
        var e = EventRecord(id: nil, jobId: job.id, stepIdx: step?.idx, at: now, kind: "state", detail: detail)
        try e.insert(db)
        return job
    }

    func startStep(job: JobRecord, step: StepRecord) throws {
        guard let recipe = installed[step.recipe] else { return }
        var step = step
        // A chained step's first input comes from the previous step's first output (refilled on every start, so retries see new outputs).
        let stepsDir = jobsDir.appending(path: "\(job.id)/steps").path
        if step.idx > 0, let first = recipe.task(step.task)?.inputs.first, step.inputs[first.name]?.hasPrefix(stepsDir) != false {
            let previous = try store.db.read { try StepRecord.fetchOne($0, key: ["jobId": job.id, "idx": step.idx - 1]) }
            guard let output = previous?.outputs.first else {
                _ = try store.db.write { db in try self.setState(db, job: job, step: step, .failed, error: "the previous step produced no output to pass on") }
                return
            }
            step.inputs[first.name] = output
        }
        let need = try store.db.read { try Estimates.need($0, recipe: recipe, task: step.task, settings: step.settings) }
        let worker = workers.values.first { $0.recipe.id == recipe.id && $0.available } ?? spawn(recipe, baseline: need.load)
        worker.idleSince = nil
        worker.job = Assignment(jobId: job.id, step: step.idx, task: step.task,
                                keyValues: Estimates.keyValues(recipe, settings: step.settings), claim: need.job)
        step.workerId = worker.id
        step.startedAt = Date()
        step.stage = nil
        step.fraction = nil
        _ = try store.db.write { db in try self.setState(db, job: job, step: step, worker.ready ? .running : .loading) }
        if worker.ready { try send(worker) }
    }

    // MARK: weights

    /// A step would start a new worker for a recipe with weights that haven't passed a check since its last start.
    func needsVerifiedStart(_ r: Recipe) -> Bool {
        !r.weights.isEmpty && !verifiedForStart.contains(r.id) && !workers.values.contains { $0.recipe.id == r.id && $0.available }
    }

    /// Starts a background weights check, at most once per `weightsRecheckInterval` per recipe.
    func requestVerify(_ r: Recipe) {
        if verifying.contains(r.id) { return }
        if let last = lastVerify[r.id], ContinuousClock.now - last < config.weightsRecheckInterval {
            // Too soon: come back when the interval ends, or a waiting job would wait for the next unrelated event.
            if recheckScheduled.insert(r.id).inserted {
                let wait = config.weightsRecheckInterval - (ContinuousClock.now - last)
                Task {
                    try? await Task.sleep(for: wait)
                    await self.recheckDue(r.id)
                }
            }
            return
        }
        verifying.insert(r.id)
        lastVerify[r.id] = .now
        let verifier = self.verifier
        Task { await self.verified(r.id, await verifier.report(r)) }
    }

    func recheckDue(_ id: String) {
        recheckScheduled.remove(id)
        tick()
    }

    func verified(_ id: String, _ report: WeightsReport?) {
        verifying.remove(id)
        weightReports[id] = report ?? WeightsReport(state: .unknown, problems: [], checkedAt: Date(), hashedFiles: 0, note: "the check itself failed")
        if report?.state == .ok { verifiedForStart.insert(id) } else { verifiedForStart.remove(id) }
        tick()
    }

    func spawn(_ recipe: Recipe, baseline: Int) -> WorkerHandle {
        verifiedForStart.remove(recipe.id)
        let id = "w-" + UUID().uuidString.prefix(8).lowercased()
        let process = WorkerProcess(
            executable: installer.venvPython(recipe.id),
            arguments: ["-u", "-m", "lift_worker", installer.workerConfig(recipe, heartbeat: config.heartbeatSeconds)],
            environment: installer.workerEnvironment(recipe),
            workingDirectory: installer.dir(recipe.id).appending(path: "repo").path)
        let handle = WorkerHandle(id: id, recipe: recipe, process: process, baseline: baseline)
        workers[id] = handle
        Task { [weak self] in
            for await event in process.events { await self?.handle(id, event) }
        }
        return handle
    }

    func send(_ w: WorkerHandle) throws {
        guard var a = w.job, !a.sent else { return }
        let step = try store.db.read { try StepRecord.fetchOne($0, key: ["jobId": a.jobId, "idx": a.step]) }
        guard let step else { return }
        let outDir = jobsDir.appending(path: "\(a.jobId)/steps/\(step.idx)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        a.sent = true
        a.startFootprint = w.lastFootprint
        w.job = a
        w.process.send(.run(job: a.jobId, step: step.idx, task: step.task, inputs: step.inputs, settings: step.settings, outDir: outDir.path))
    }

    /// Cancel/kill: SIGKILL to the worker's whole process group, at once (spec §8). Its exit is expected, and
    /// nothing it still sends counts: results are only taken from the worker a step is on (`step.workerId`),
    /// so a line already in its pipe can't land on a retry that started elsewhere.
    func kill(_ w: WorkerHandle) {
        w.stopping = true
        w.job = nil
        w.process.kill()
    }

    // MARK: worker events

    func footprint(_ w: WorkerHandle, mps: Int = 0) -> Int {
        max(Memory.footprint(pid: w.pid) ?? 0, mps)
    }

    func handle(_ workerId: String, _ event: WorkerEvent) {
        guard let w = workers[workerId] else { return }
        do {
            switch event {
            case .started(let pid):
                w.pid = pid
                try store.db.write { try WorkerRecord(id: w.id, recipe: w.recipe.id, pid: pid, startedAt: Date()).insert($0) }
            case .ready(_, let loadSeconds):
                w.ready = true
                w.lastFootprint = footprint(w)
                w.baseline = w.lastFootprint
                try store.db.write { db in
                    try db.execute(sql: "UPDATE worker SET loadSeconds = ? WHERE id = ?", arguments: [loadSeconds, w.id])
                    if let a = w.job {
                        try Estimates.record(db, recipe: w.recipe.id, task: a.task, keyValues: a.keyValues, kind: .load, bytes: w.baseline)
                    }
                }
                if let a = w.job, !a.sent {
                    let stillWanted = try store.db.write { db -> Bool in
                        guard let j = try JobRecord.fetchOne(db, key: a.jobId),
                              let s = try StepRecord.fetchOne(db, key: ["jobId": a.jobId, "idx": a.step]), s.state == .loading else { return false }
                        try self.setState(db, job: j, step: s, .running)
                        return true
                    }
                    if stillWanted { try send(w) } else { w.job = nil; w.idleSince = .now }
                }
            case .log(let job, let line):
                appendLog(job, line)
            case .stage(let job, let name, let fraction):
                guard let a = w.job, a.jobId == job else { return }
                try store.db.write { db in
                    try db.execute(sql: "UPDATE step SET stage = ?, fraction = ? WHERE jobId = ? AND idx = ? AND state = 'running' AND workerId = ?",
                                   arguments: [name, fraction, a.jobId, a.step, w.id])
                }
            case .done(let job, let outputs):
                try finish(w, job: job, outputs: outputs, error: nil)
            case .error(let job?, let message, let traceback):
                if let traceback { appendLog(job, traceback) }
                try finish(w, job: job, outputs: [], error: message)
            case .error(nil, let message, let traceback):
                w.loadError = message
                for line in (traceback ?? "").split(separator: "\n") { w.tail.append(String(line)) }
            case .heartbeat(let mps):
                w.lastFootprint = footprint(w, mps: mps)
                if var a = w.job, a.sent {
                    a.peak = max(a.peak, w.lastFootprint)
                    w.job = a
                }
                if waitingForMemory { tick() }
            case .stderr(let line):
                w.tail.append(line)
                if let a = w.job { appendLog(a.jobId, line) }
            case .malformed(let line):
                w.tail.append("[malformed protocol line] " + line)
            case .exited(let code):
                try exited(w, code: code)
            }
        } catch {
            print("lift: handling \(event) from \(workerId) failed: \(error)")
        }
    }

    func appendLog(_ job: String, _ line: String) {
        if logs[job] == nil { logs[job] = try? LogFile(jobsDir.appending(path: "\(job)/log.txt")) }
        logs[job]?.write(line)
    }

    func finish(_ w: WorkerHandle, job id: String, outputs: [String], error: String?) throws {
        guard var a = w.job, a.jobId == id else { return }
        w.job = nil
        w.idleSince = .now
        w.lastFootprint = footprint(w)
        a.peak = max(a.peak, w.lastFootprint)
        let jobBytes = max(0, a.peak - a.startFootprint)
        try store.db.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id),
                  var step = try StepRecord.fetchOne(db, key: ["jobId": id, "idx": a.step]),
                  step.state == .running, step.workerId == w.id else { return }  // cancelled, or retried elsewhere: discarded
            if let error {
                try self.setState(db, job: job, step: step, .failed, error: w.recipe.failureMessage(error))
                return
            }
            try Estimates.record(db, recipe: w.recipe.id, task: a.task, keyValues: a.keyValues, kind: .job, bytes: jobBytes)
            step.outputs = outputs
            step.fraction = 1
            let stepCount = try StepRecord.filter(Column("jobId") == id).fetchCount(db)
            if step.idx + 1 < stepCount {
                step.state = .succeeded
                step.finishedAt = Date()
                try step.update(db)
                job.currentStep = step.idx + 1
                try self.setState(db, job: job, step: nil, .queued)
            } else {
                job.exportPending = job.export != nil  // in the same write, so jobs_wait never sees "done" before the export
                try self.setState(db, job: job, step: step, .succeeded)
            }
        }
        let after = try store.db.read { try JobRecord.fetchOne($0, key: id) }
        if after?.state.isTerminal == true { logs[id] = nil }
        if let after, after.exportPending, let spec = after.export { Task { try? await self.export(id, spec) } }
        tick()
    }

    func exited(_ w: WorkerHandle, code: Int32) throws {
        workers[w.id] = nil
        let reason = w.stopping ? "stopped" : "exited with code \(code)"
        try store.db.write { db in
            try db.execute(sql: "UPDATE worker SET endedAt = ?, endReason = ? WHERE id = ?", arguments: [Date(), reason, w.id])
        }
        guard !closing else { return }
        let message = ([w.loadError ?? "worker \(reason)"] + w.tail.lines.suffix(20)).joined(separator: "\n")
        if let a = w.job {
            let id = a.jobId
            try store.db.write { db in
                if let job = try JobRecord.fetchOne(db, key: id), let step = try StepRecord.fetchOne(db, key: ["jobId": id, "idx": a.step]), step.state.isActive, step.workerId == w.id {
                    try self.setState(db, job: job, step: step, .failed, error: w.recipe.failureMessage(message))
                }
            }
            logs[id] = nil
        }
        tick()
    }

    // MARK: housekeeping

    func housekeep() {
        if waitingForMemory { tick() }
        let limit = Duration.seconds(settings.idleUnloadMinutes * 60)
        for w in workers.values where w.available {
            if let idle = w.idleSince, ContinuousClock.now - idle >= limit { stop(w) }
        }
    }

    /// Asks a worker to exit, and kills it if it hasn't within 5 s.
    func stop(_ w: WorkerHandle) {
        w.stopping = true
        w.process.send(.shutdown)
        let process = w.process
        Task {
            try? await Task.sleep(for: .seconds(5))
            process.kill()
        }
    }
}
