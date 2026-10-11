import Foundation
import LiftCore
import LiftServer
import Observation

/// Where Lift.app keeps what it ships: `Contents/Resources/dev-recipes`, `Contents/Resources/lift_worker`
/// and `Contents/MacOS/lift-mcp`.
public struct AppPaths: Sendable {
    public var bundledRecipes: URL
    /// The folder holding the `lift_worker` package.
    public var workerSource: URL
    public var bridge: URL?

    public init(bundledRecipes: URL, workerSource: URL, bridge: URL?) {
        self.bundledRecipes = bundledRecipes
        self.workerSource = workerSource
        self.bridge = bridge
    }

    public static var main: AppPaths {
        let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
        let bridge = Bundle.main.bundleURL.appending(path: "Contents/MacOS/lift-mcp")
        return AppPaths(bundledRecipes: resources.appending(path: "dev-recipes"), workerSource: resources,
                        bridge: FileManager.default.isExecutableFile(atPath: bridge.path) ? bridge : nil)
    }
}

public enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case generate, queue, history, models, settings
    public var id: String { rawValue }
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    public var symbol: String {
        switch self {
        case .generate: "square.and.arrow.up"
        case .queue: "list.bullet"
        case .history: "square.grid.2x2"
        case .models: "shippingbox"
        case .settings: "gearshape"
        }
    }
}

/// The two values the app keeps outside the workdir: which workdir, and whether the wizard finished.
/// `UserDefaults` in the app; a dictionary in tests, so they never write the user's preferences.
public protocol PreferenceStore: AnyObject {
    func string(forKey key: String) -> String?
    func bool(forKey key: String) -> Bool
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: PreferenceStore {}

/// A risky command (or a memory warning) waiting for the user's OK: `message` is LiftCore's own text,
/// `action` the OK button's title.
public struct Confirmation: Identifiable {
    public let id = UUID()
    public let message: String
    public var action = "Continue"
    let run: @MainActor () async -> Void

    @MainActor public func confirm() async { await run() }
}

/// Something a notification reports (spec §8, §11).
public enum JobEvent: Equatable, Sendable {
    case finished(JobView)
    case waitingForMemory(JobView)
}

/// The app's state: owns the `Lift` engine (in-process) and the HTTP/MCP server, and mirrors the
/// queue, resources, models and settings for the views. Every action goes through a `Lift` command.
@MainActor @Observable
public final class AppModel {
    public enum Phase: Equatable {
        case loading, setup, ready
        case failed(String)
    }

    public private(set) var phase = Phase.loading
    public private(set) var lift: Lift?
    public private(set) var server: LiftServer?
    public private(set) var serverStatus: ServerStatus?
    public private(set) var queue: QueueStatus?
    public private(set) var resources: ResourcesView?
    public private(set) var models: [ModelView] = []
    public private(set) var settings = Settings()
    /// Jobs found interrupted at launch, until resolved or put off (spec §7).
    public var interrupted: [JobView] = []
    /// The most recent job that finished while the app was watching (menu bar "Just finished").
    public private(set) var lastFinished: JobView?
    public var confirmation: Confirmation?
    public var alert: String?
    public var section = AppSection.generate
    public let generate = GenerateModel()

    /// Called with each finished job and each new memory wait (the app posts notifications).
    public var onEvent: (@MainActor (JobEvent) -> Void)?
    /// Applies `launch_at_login` to the system (ServiceManagement in the app; a fake in tests).
    public var applyLaunchAtLogin: (@MainActor (Bool) throws -> Void)?
    public var launchAtLoginEnabled: (@MainActor () -> Bool)?

    let defaults: any PreferenceStore
    let paths: AppPaths
    let secrets: any SecretStore
    let serverPort: Int?
    var refresher: Task<Void, Never>?
    var seen: [String: JobView] = [:]

    static let workdirKey = "workdir"
    static let setupKey = "setupDone"
    static let setupStepKey = "setupStep"

    /// `serverPort`: nil uses the `port` setting; 0 picks any free port (tests).
    public init(defaults: any PreferenceStore = UserDefaults.standard, paths: AppPaths = .main, secrets: any SecretStore = KeychainSecretStore(),
                serverPort: Int? = nil) {
        self.defaults = defaults
        self.paths = paths
        self.secrets = secrets
        self.serverPort = serverPort
    }

    /// The open engine, for actions; throws when Lift isn't open (the views only offer actions when it is).
    public var engine: Lift {
        get throws {
            guard let lift else { throw LiftError.invalidState("Lift isn't open") }
            return lift
        }
    }

    public var liveServer: LiftServer {
        get throws {
            guard let server else { throw LiftError.invalidState("the server isn't running") }
            return server
        }
    }

    public var workdir: URL? {
        defaults.string(forKey: Self.workdirKey).map { URL(filePath: $0) }
    }

    /// The wizard step reached so far, so an interrupted setup resumes where it stopped (spec §1).
    public var setupStep: Int {
        get { Int(defaults.string(forKey: Self.setupStepKey) ?? "") ?? 0 }
        set { defaults.set(String(newValue), forKey: Self.setupStepKey) }
    }

    /// Developer mode (Settings → Developer): shows the Test Cube and the recipes' raw details (spec §1).
    public var developer: Bool { settings.devRecipes }

    /// At launch: open the saved workdir, or show the first-launch wizard (spec §11) until it's finished.
    /// A wizard stopped after its first step reopens the workdir and resumes.
    public func start() async {
        guard let workdir else { phase = .setup; return }
        if defaults.bool(forKey: Self.setupKey) {
            await open(workdir)
        } else {
            await open(workdir, ready: false)
            phase = .setup
        }
    }

    /// Back to the wizard, e.g. after the workdir failed to open.
    public func restartSetup() {
        defaults.set(false, forKey: Self.setupKey)
        phase = .setup
    }

    /// The wizard's last step.
    public func finishSetup() {
        defaults.set(true, forKey: Self.setupKey)
        phase = .ready
    }

    /// Opens (creating if needed) the workdir, starts the server, and loads interrupted jobs.
    /// `ready: false` keeps the wizard on screen (it opens Lift halfway through).
    @discardableResult
    public func open(_ workdir: URL, ready: Bool = true) async -> Bool {
        if lift != nil { await close() }
        do {
            let runtime = try installRuntime(in: workdir)
            let lift = try await Lift.open(LiftConfig(workdir: workdir, workerRuntime: runtime, bundledRecipes: paths.bundledRecipes,
                                                      hfToken: secrets.hfTokenReader))
            let server = LiftServer(lift: lift, configuration: .init(secrets: secrets, port: serverPort, bridgePath: paths.bridge?.path))
            self.lift = lift
            self.server = server
            if self.workdir != workdir { defaults.set(workdir.path, forKey: Self.workdirKey) }
            do {
                serverStatus = try await server.start()
            } catch {
                self.server = nil  // the badge and Settings then say it isn't running
                alert = "The HTTP/MCP server didn't start: \(Format.error(error))"
            }
            interrupted = try await lift.jobsListInterrupted()
            await refresh()
            if ready { phase = .ready }
            refresher = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    await self?.refresh()
                }
            }
            return true
        } catch {
            if ready { phase = .failed(Format.error(error)) } else { alert = Format.error(error) }
            return false
        }
    }

    /// Copies the bundled `lift_worker` to `<workdir>/runtime/`, so Python's bytecode cache never
    /// writes into the signed app bundle. Replaced on every launch (it's a few files).
    func installRuntime(in workdir: URL) throws -> URL {
        let fm = FileManager.default
        let runtime = workdir.appending(path: "runtime")
        let dest = runtime.appending(path: "lift_worker")
        try fm.createDirectory(at: runtime, withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: paths.workerSource.appending(path: "lift_worker"), to: dest)
        return runtime
    }

    public func close() async {
        refresher?.cancel()
        refresher = nil
        await server?.stop()
        await lift?.close()
        server = nil
        lift = nil
    }

    // MARK: mirror

    public func refresh() async {
        guard let lift else { return }
        do {
            let queue = try await lift.queueStatus()
            let resources = try await lift.resourcesGet()
            let models = try await lift.modelsList()
            let settings = await lift.settingsGet()
            let status = await server?.status()
            await report(queue.jobs, lift: lift)
            // Assign only changes: every assignment re-renders the views that read it.
            if self.queue != queue { self.queue = queue }
            if self.resources != resources { self.resources = resources }
            if self.models != models { self.models = models; generate.models = models }
            if self.settings != settings { self.settings = settings }
            if serverStatus != status { serverStatus = status }
            reconcileLaunchAtLogin()
        } catch {
            if alert == nil { alert = Format.error(error) }  // once, not every second
        }
    }

    /// Finished jobs leave the queue: each one that left is fetched once, then reported with any new memory waits.
    func report(_ jobs: [JobView], lift: Lift) async {
        let ids = Set(jobs.map(\.job.id))
        var left: [JobView] = []
        for id in seen.keys where !ids.contains(id) {
            if let v = try? await lift.jobsGet(id) { left.append(v) }
        }
        for event in Self.events(previous: seen, current: jobs, left: left) {
            if case .finished(let v) = event { lastFinished = v }
            onEvent?(event)
        }
        seen = Dictionary(uniqueKeysWithValues: jobs.map { ($0.job.id, $0) })
    }

    /// What to notify: jobs that left the queue succeeded or failed (not cancelled), and jobs that just
    /// started waiting for memory.
    static func events(previous: [String: JobView], current: [JobView], left: [JobView]) -> [JobEvent] {
        func memoryWait(_ v: JobView?) -> Bool {
            if case .memory = v?.job.waitReason { true } else { false }
        }
        let waits = current.filter { memoryWait($0) && !memoryWait(previous[$0.job.id]) }.map(JobEvent.waitingForMemory)
        let done = left.filter { $0.job.state == .succeeded || $0.job.state == .failed }.map(JobEvent.finished)
        return waits + done
    }

    func reconcileLaunchAtLogin() {
        guard let apply = applyLaunchAtLogin, let enabled = launchAtLoginEnabled, settings.launchAtLogin != enabled() else { return }
        do {
            try apply(settings.launchAtLogin)
        } catch {
            alert = "Launch at login: \(Format.error(error))"
            let actual = enabled()
            run { _ = try await self.lift?.settingsSet("launch_at_login", .bool(actual)) }
        }
    }

    // MARK: actions

    /// Runs a command, showing any error in an alert, then refreshes.
    public func run(_ body: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await body() } catch { alert = Format.error(error) }
            await refresh()
        }
    }

    /// Runs a confirm-gated command: without confirmation first, and if it answers
    /// `confirmationRequired`, shows the impact and runs it again with `confirm: true` on OK.
    public func gated<T: Sendable>(_ call: @escaping @MainActor (_ confirm: Bool) async throws -> Gated<T>,
                                   then done: @escaping @MainActor (T) -> Void = { _ in }) {
        run {
            switch try await call(false) {
            case .done(let value): done(value)
            case .confirmationRequired(let impact):
                self.confirmation = Confirmation(message: impact) { [weak self] in
                    self?.run { if let value = try await call(true).value { done(value) } }
                }
            }
        }
    }

    /// Queues the Generate form: one job per input file. Bad input (per field) stays in the form. A memory
    /// warning (spec §8) asks once: Run anyway queues this file and the rest; Cancel queues nothing more.
    public func submitGenerate() {
        submit(generate.requests[...], accept: false)
    }

    func submit(_ requests: ArraySlice<SubmitRequest>, accept: Bool) {
        run {
            let lift = try self.engine
            self.generate.errors = []
            for (i, request) in zip(requests.indices, requests) {
                do {
                    if case .memoryWarning(let w) = try await lift.jobsSubmit(request, acceptMemoryWarning: accept) {
                        self.confirmation = Confirmation(message: w.message, action: "Run Anyway") { [weak self] in
                            self?.submit(requests[i...], accept: true)
                        }
                        return
                    }
                } catch LiftError.invalidInput(let errors) {
                    self.generate.errors = errors
                    return
                }
            }
            self.generate.files = []
            self.generate.text = ""
        }
    }

    /// `jobs_retry`, with the same memory-warning question as submitting.
    public func retry(_ id: String, settings: [String: SettingValue]? = nil, accept: Bool = false) async throws {
        if case .memoryWarning(let w) = try await engine.jobsRetry(id, settings: settings, acceptMemoryWarning: accept) {
            confirmation = Confirmation(message: w.message, action: "Run Anyway") { [weak self] in
                self?.run { try await self?.retry(id, settings: settings, accept: true) }
            }
        }
    }

    public func resolveInterrupted(_ action: InterruptedAction) {
        let ids = interrupted.map(\.job.id)
        interrupted = []
        run { _ = try await self.lift?.jobsResolveInterrupted(ids: ids, action: action) }
    }

    /// The end of a job's log (`<workdir>/jobs/<id>/log.txt`).
    public func logTail(_ job: String, maxBytes: Int = 16_384) -> String {
        guard let workdir, let handle = try? FileHandle(forReadingFrom: workdir.appending(path: "jobs/\(job)/log.txt")) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// Moves the working directory (database, recipes, models, jobs) and reopens Lift there.
    /// Needs confirmation; workers stop and running jobs come back as interrupted.
    public func moveWorkdir(to destination: URL) {
        guard let from = workdir else { return }
        let message = "Moves Lift's working directory from \(from.path) to \(destination.path). Workers stop, "
            + "running jobs come back as interrupted, and the HTTP/MCP server restarts. Installed models may need Reinstall "
            + "if their environment has absolute paths."
        confirmation = Confirmation(message: message) { [weak self] in
            guard let self else { return }
            await self.close()
            do {
                try FileManager.default.moveItem(at: from, to: destination)
                await self.open(destination)
            } catch {
                self.alert = Format.error(error)
                await self.open(from)
            }
        }
    }
}
