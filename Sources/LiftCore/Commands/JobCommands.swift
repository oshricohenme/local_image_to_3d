import Foundation
import GRDB

public struct StepRequest: Codable, Sendable, Equatable {
    public var recipe: String
    public var task: String
    /// Input name → file/folder path (or text). A chained step may leave its first input out.
    public var inputs: [String: String]
    public var settings: [String: SettingValue]

    public init(recipe: String, task: String, inputs: [String: String] = [:], settings: [String: SettingValue] = [:]) {
        self.recipe = recipe
        self.task = task
        self.inputs = inputs
        self.settings = settings
    }
}

public struct SubmitRequest: Codable, Sendable, Equatable {
    public var steps: [StepRequest]
    public var title: String?
    public var priority: Priority
    public var source: JobSource
    /// nil fields (or a nil `export`) take the export settings; `formats: []` means no export.
    public var export: ExportSpec?

    public init(steps: [StepRequest], title: String? = nil, priority: Priority = .normal, source: JobSource = .ui, export: ExportSpec? = nil) {
        self.steps = steps
        self.title = title
        self.priority = priority
        self.source = source
        self.export = export
    }
}

public struct JobFilter: Codable, Sendable, Equatable {
    public var states: [JobState]?
    public var recipe: String?
    public var modality: String?
    /// Case-insensitive match on the title.
    public var text: String?

    public init(states: [JobState]? = nil, recipe: String? = nil, modality: String? = nil, text: String? = nil) {
        self.states = states
        self.recipe = recipe
        self.modality = modality
        self.text = text
    }
}

public struct JobView: Codable, Sendable, Equatable {
    public var job: JobRecord
    public var steps: [StepRecord]
    /// Who made the model behind the job's result (the last step's recipe); every step's is in `job.credits`.
    public var attribution: Attribution?
    /// The last step's outputs once the job succeeded.
    public var outputs: [String] { job.state == .succeeded ? steps.last?.outputs ?? [] : [] }

    public init(job: JobRecord, steps: [StepRecord]) {
        self.job = job
        self.steps = steps
        attribution = job.credits.last
    }

    static func fetch(_ db: Database, _ id: String) throws -> JobView? {
        guard let job = try JobRecord.fetchOne(db, key: id) else { return nil }
        return JobView(job: job, steps: try StepRecord.filter(Column("jobId") == id).order(Column("idx")).fetchAll(db))
    }
}

public enum MoveTarget: Codable, Sendable, Equatable {
    case before(String)
    case after(String)
    /// 0-based index among unfinished jobs ordered by position.
    case index(Int)
}

public enum InterruptedAction: String, Codable, Sendable {
    case requeue, discard
}

extension Lift {
    func view(_ id: String) throws -> JobView {
        guard let v = try store.db.read({ try JobView.fetch($0, id) }) else { throw LiftError.notFound("job \(id)") }
        return v
    }

    // MARK: jobs_submit

    /// Validates every step (recipe, task, settings, inputs, chain types), copies inputs into
    /// `jobs/<id>/inputs/` (off the actor), and queues the job. Bad input throws `invalidInput` with per-field errors.
    public func jobsSubmit(_ request: SubmitRequest, acceptMemoryWarning: Bool = false) async throws -> Admission<JobView> {
        guard !request.steps.isEmpty else { throw LiftError.invalidInput([FieldError("steps", "at least one step is required")]) }
        var errors: [FieldError] = []
        var checked: [(StepRequest, RecipeTask)] = []
        for (i, s) in request.steps.enumerated() {
            let prefix = "steps[\(i)]"
            guard let recipe = recipe(s.recipe) else { errors.append(FieldError("\(prefix).recipe", "unknown recipe \(s.recipe)")); continue }
            guard let task = recipe.task(s.task) else { errors.append(FieldError("\(prefix).task", "unknown task \(s.task)")); continue }
            if i > 0, let previous = checked.last?.1, let first = task.inputs.first, !first.type.accepts(previous.output) {
                errors.append(FieldError("\(prefix).task", "\(task.id) takes \(first.type.rawValue) but the previous step outputs \(previous.output.rawValue)"))
            }
            var step = s
            do { step.settings = try task.validated(settings: s.settings, prefix: "\(prefix).settings") } catch { if case .invalidInput(let e) = error { errors += e } }
            do { step.inputs = try task.validated(inputs: s.inputs, chained: i > 0, prefix: "\(prefix).inputs", workdir: config.workdir) } catch { if case .invalidInput(let e) = error { errors += e } }
            checked.append((step, task))
        }
        let wanted = ExportSpec(dir: request.export?.dir ?? settings.exportDir,
                                formats: request.export?.formats ?? settings.exportFormats,
                                cleanupAfterExport: request.export?.cleanupAfterExport ?? settings.cleanupAfterExport)
        if wanted.dir == nil && request.export?.formats?.isEmpty == false {
            errors.append(FieldError("export.dir", "no export folder: give export.dir or set export_dir"))
        }
        let export = wanted.dir == nil || wanted.formats?.isEmpty != false ? nil : wanted  // no folder chosen yet, or formats: []
        let credits = checked.compactMap { recipe($0.0.recipe)?.attribution }.reduce(into: [Attribution]()) { all, a in
            if !all.contains(a) { all.append(a) }
        }
        if !errors.isEmpty { throw LiftError.invalidInput(errors) }
        let warning = try memoryWarning(checked.map { ($0.0.recipe, $0.0.task, $0.0.settings) }, firstIndex: 0)
        if let warning, !acceptMemoryWarning { return .memoryWarning(warning) }

        let id = UUID().uuidString.lowercased()
        let now = Date()
        let jobDir = jobsDir.appending(path: id)
        let plan = checked.map { s, task in (s, task.inputs) }
        let steps = try await Task.detached { try Self.copyInputs(plan, into: jobDir) }.value.enumerated().map { i, inputs in
            StepRecord(jobId: id, idx: i, recipe: plan[i].0.recipe, task: plan[i].0.task, inputs: inputs, settings: plan[i].0.settings,
                       state: .queued, outputs: [])
        }
        let firstInput = request.steps[0].inputs.values.first.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
        try await store.db.write { db in
            let position = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM job") ?? 0) + 1
            let job = JobRecord(id: id, title: request.title ?? firstInput ?? request.steps[0].recipe, priority: request.priority,
                                position: position, source: request.source, state: .queued, forceStart: false,
                                memoryAccepted: warning != nil, currentStep: 0, createdAt: now, updatedAt: now,
                                export: export, credits: credits)
            try job.insert(db)
            for step in steps { try step.insert(db) }
            var e = EventRecord(id: nil, jobId: id, stepIdx: nil, at: now, kind: "state", detail: "queued")
            try e.insert(db)
        }
        tick()
        return .accepted(try view(id))
    }

    /// The first step whose memory estimate (a new worker: load + job) is above this Mac's RAM or the budget.
    func memoryWarning(_ steps: [(recipe: String, task: String, settings: [String: SettingValue])], firstIndex: Int) throws -> MemoryWarning? {
        let physical = config.physicalMemory, budget = settings.memoryBudgetBytes
        for (i, s) in steps.enumerated() {
            guard let r = recipe(s.recipe) else { continue }
            let need = try store.db.read { try Estimates.need($0, recipe: r, task: s.task, settings: s.settings) }.newWorker
            guard need > physical || need > budget else { continue }
            func gb(_ b: Int, binary: Bool = false) -> Double { Double(b) / (binary ? 1_073_741_824 : 1e9) }
            func text(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...1))) }
            let (neededGB, physicalGB, budgetGB) = (gb(need), gb(physical, binary: true), gb(budget))
            let message = need > physical
                ? "This model usually needs about \(text(neededGB)) GB; this Mac has \(text(physicalGB)) GB. It may be very slow or fail."
                : "This model usually needs about \(text(neededGB)) GB; your memory budget is \(text(budgetGB)) GB (this Mac has \(text(physicalGB)) GB). It may be very slow or fail."
            return MemoryWarning(message: message, neededGB: neededGB, physicalGB: physicalGB, budgetGB: budgetGB, step: firstIndex + i)
        }
        return nil
    }

    /// Copies each step's file inputs into `<jobDir>/inputs/<step>-<name>/`; an image set copies only its
    /// listed files. Returns each step's input map. Runs off the actor: inputs can be large.
    nonisolated static func copyInputs(_ plan: [(StepRequest, [TaskInput])], into jobDir: URL) throws -> [[String: String]] {
        let fm = FileManager.default
        return try plan.enumerated().map { i, entry in
            var inputs: [String: String] = [:]
            for input in entry.1 {
                guard let value = entry.0.inputs[input.name] else { continue }
                if input.type == .text { inputs[input.name] = value; continue }
                let source = URL(filePath: value)
                let dest = jobDir.appending(path: "inputs/\(i)-\(input.name)/\(source.lastPathComponent)")
                if input.type == .imageSet {
                    try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                    for f in ImageSet.files(source) ?? [] { try fm.copyItem(at: f, to: dest.appending(path: f.lastPathComponent)) }
                } else {
                    try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: source, to: dest)
                }
                inputs[input.name] = dest.path
            }
            return inputs
        }
    }

    // MARK: reading

    public func jobsGet(_ id: String) throws -> JobView { try view(id) }

    /// Newest first.
    public func jobsList(_ filter: JobFilter = JobFilter()) throws -> [JobView] {
        let modalityRecipes = filter.modality.map { m in Set((catalog.entries.values.map(\.recipe) + installed.values).filter { $0.tasks.contains { $0.modality == m } }.map(\.id)) }
        return try store.db.read { db in
            var request = JobRecord.order(Column("createdAt").desc)
            if let states = filter.states { request = request.filter(states.map(\.rawValue).contains(Column("state"))) }
            if let text = filter.text { request = request.filter(Column("title").like("%\(text)%")) }
            return try request.fetchAll(db).compactMap { try JobView.fetch(db, $0.id) }.filter { v in
                (filter.recipe == nil || v.steps.contains { $0.recipe == filter.recipe })
                    && (modalityRecipes == nil || v.steps.contains { modalityRecipes!.contains($0.recipe) })
            }
        }
    }

    /// Waits until the job finishes or `timeout` passes, calling `onProgress` on every change
    /// (state, stage, fraction). Returns the job as it is at the end.
    public nonisolated func jobsWait(_ id: String, timeout: Duration, onProgress: @escaping @Sendable (JobView) -> Void = { _ in }) async throws -> JobView {
        let store = self.store
        return try await withThrowingTaskGroup(of: JobView?.self) { group in
            group.addTask {
                for try await v in ValueObservation.tracking({ try JobView.fetch($0, id) }).values(in: store.db) {
                    guard let v else { throw LiftError.notFound("job \(id)") }
                    onProgress(v)
                    if v.job.state.isTerminal && !v.job.exportPending { return v }
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            if let first { return first }
            guard let v = try await store.db.read({ try JobView.fetch($0, id) }) else { throw LiftError.notFound("job \(id)") }
            return v
        }
    }

    // MARK: changing jobs

    /// Queued, waiting or interrupted jobs are cancelled at once. A loading or running job needs `confirm`, and
    /// its worker is killed with its whole process group at once (spec §8); the next job gets a fresh worker.
    /// A job cancelled while its worker is still loading never runs: that worker was loading only for it.
    public func jobsCancel(_ id: String, confirm: Bool = false) throws -> Gated<JobView> {
        let v = try view(id)
        guard !v.job.state.isTerminal else { throw LiftError.invalidState("job \(id) already \(v.job.state.rawValue)") }
        let step = v.steps[v.job.currentStep]
        if v.job.state.isActive {
            guard confirm else { return .confirmationRequired("Stops this job immediately. Its progress will be lost.") }
            _ = try store.db.write { db in try self.setState(db, job: v.job, step: step, .cancelled) }
            if let w = workers.values.first(where: { $0.job?.jobId == id }) { kill(w) }
        } else {
            _ = try store.db.write { db in try self.setState(db, job: v.job, step: step, .cancelled) }
        }
        tick()
        return .done(try view(id))
    }

    /// Re-queues a finished job from its first unfinished step (all steps if it succeeded).
    /// `settings` replaces that step's settings (validated) when given.
    public func jobsRetry(_ id: String, settings: [String: SettingValue]? = nil, acceptMemoryWarning: Bool = false) throws -> Admission<JobView> {
        let v = try view(id)
        guard v.job.state.isTerminal || v.job.state == .interrupted else { throw LiftError.invalidState("job \(id) is \(v.job.state.rawValue); only finished jobs can be retried") }
        guard !v.job.cleanedUp else { throw LiftError.invalidState("This job's files were deleted after it was exported, so it can't run again.") }
        let from = v.steps.firstIndex { $0.state != .succeeded } ?? 0
        var newSettings: [String: SettingValue]?
        if let settings {
            let s = v.steps[from]
            guard let task = recipe(s.recipe)?.task(s.task) else { throw LiftError.notFound("recipe \(s.recipe)") }
            newSettings = try task.validated(settings: settings, prefix: "settings")
        }
        let warning = try memoryWarning(v.steps.filter { $0.idx >= from }.map { s in (s.recipe, s.task, s.idx == from ? newSettings ?? s.settings : s.settings) },
                                        firstIndex: from)
        if let warning, !acceptMemoryWarning { return .memoryWarning(warning) }
        try store.db.write { db in
            for var s in v.steps where s.idx >= from {
                s.state = .queued
                s.waitReason = nil
                s.error = nil
                s.outputs = []
                s.stage = nil
                s.fraction = nil
                s.workerId = nil
                s.startedAt = nil
                s.finishedAt = nil
                if s.idx == from, let newSettings { s.settings = newSettings }
                try s.update(db)
            }
            var job = v.job
            job.currentStep = from
            job.memoryAccepted = warning != nil
            job.error = nil
            job.finishedAt = nil
            try self.setState(db, job: job, step: nil, .queued)
        }
        tick()
        return .accepted(try view(id))
    }

    /// Sets the job's manual position among unfinished jobs and renumbers them 1…n.
    public func jobsMove(_ id: String, to target: MoveTarget) throws -> JobView {
        try store.db.write { db in
            var order = try JobRecord.filter(![JobState.succeeded.rawValue, JobState.failed.rawValue, JobState.cancelled.rawValue].contains(Column("state")))
                .order(Column("position")).fetchAll(db)
            guard let from = order.firstIndex(where: { $0.id == id }) else { throw LiftError.notFound("unfinished job \(id)") }
            let job = order.remove(at: from)
            let index: Int
            switch target {
            case .before(let other):
                guard let i = order.firstIndex(where: { $0.id == other }) else { throw LiftError.notFound("unfinished job \(other)") }
                index = i
            case .after(let other):
                guard let i = order.firstIndex(where: { $0.id == other }) else { throw LiftError.notFound("unfinished job \(other)") }
                index = i + 1
            case .index(let i):
                index = min(max(0, i), order.count)
            }
            order.insert(job, at: index)
            for (n, var j) in order.enumerated() where j.position != Double(n + 1) {
                j.position = Double(n + 1)
                try j.update(db)
            }
        }
        tick()
        return try view(id)
    }

    public func jobsSetPriority(_ id: String, _ priority: Priority) throws -> JobView {
        try store.db.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id) else { throw LiftError.notFound("job \(id)") }
            job.priority = priority
            try job.update(db)
        }
        tick()
        return try view(id)
    }

    /// Skips the memory checks for this job (not the slot check).
    public func jobsForceStart(_ id: String, confirm: Bool = false) throws -> Gated<JobView> {
        let v = try view(id)
        guard v.job.state == .queued || v.job.state == .waiting else { throw LiftError.invalidState("job \(id) is \(v.job.state.rawValue)") }
        guard confirm else {
            return .confirmationRequired("Starts \"\(v.job.title)\" without checking the memory budget or free system memory; the Mac may swap or the worker may run out of memory.")
        }
        try store.db.write { db in
            var job = v.job
            job.forceStart = true
            try job.update(db)
        }
        tick()
        return .done(try view(id))
    }

    /// Deletes the job record and its folder. A running job is stopped first.
    public func jobsDelete(_ id: String, confirm: Bool = false) throws -> Gated<Bool> {
        let v = try view(id)
        guard confirm else { return .confirmationRequired("Deletes job \"\(v.job.title)\", its inputs, outputs and log. This can't be undone.") }
        if !v.job.state.isTerminal { _ = try jobsCancel(id, confirm: true) }
        _ = try store.db.write { try JobRecord.deleteOne($0, key: id) }
        logs[id] = nil
        try? FileManager.default.removeItem(at: jobsDir.appending(path: id))
        return .done(true)
    }

    public func jobsListInterrupted() throws -> [JobView] {
        try jobsList(JobFilter(states: [.interrupted]))
    }

    /// `requeue` restarts from the interrupted step (finished steps are kept); `discard` cancels.
    /// `ids == nil` means every interrupted job.
    public func jobsResolveInterrupted(ids: [String]? = nil, action: InterruptedAction) throws -> [JobView] {
        let targets = try jobsListInterrupted().filter { ids == nil || ids!.contains($0.job.id) }
        try store.db.write { db in
            for v in targets {
                let step = v.steps[v.job.currentStep]
                switch action {
                case .requeue:
                    var s = step
                    s.stage = nil
                    s.fraction = nil
                    try self.setState(db, job: v.job, step: s, .queued)
                case .discard:
                    try self.setState(db, job: v.job, step: step, .cancelled)
                }
            }
        }
        tick()
        return try targets.map { try view($0.job.id) }
    }

    // MARK: queue

    public func queueStatus() throws -> QueueStatus {
        let pending = try jobsList(JobFilter(states: [.queued, .waiting, .loading, .running]))
        let order = pending.sorted { a, b in
            if a.job.priority.rank != b.job.priority.rank { return a.job.priority.rank > b.job.priority.rank }
            if a.job.position != b.job.position { return a.job.position < b.job.position }
            return a.job.createdAt < b.job.createdAt
        }
        return QueueStatus(paused: settings.queuePaused, maxSlots: settings.maxSlots,
                           running: workers.values.filter { $0.job != nil }.count, jobs: order)
    }

    public func queuePause() throws -> QueueStatus {
        var s = settings
        s.queuePaused = true
        try saveSettings(s)
        tick()
        return try queueStatus()
    }

    public func queueResume() throws -> QueueStatus {
        var s = settings
        s.queuePaused = false
        try saveSettings(s)
        tick()
        return try queueStatus()
    }
}

public struct QueueStatus: Codable, Sendable, Equatable {
    public var paused: Bool
    public var maxSlots: Int
    public var running: Int
    /// Unfinished jobs in scheduling order.
    public var jobs: [JobView]
}
