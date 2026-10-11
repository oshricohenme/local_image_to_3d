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

    public init(steps: [StepRequest], title: String? = nil, priority: Priority = .normal, source: JobSource = .ui) {
        self.steps = steps
        self.title = title
        self.priority = priority
        self.source = source
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
    /// The last step's outputs once the job succeeded.
    public var outputs: [String] { job.state == .succeeded ? steps.last?.outputs ?? [] : [] }

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
    /// `jobs/<id>/inputs/`, and queues the job. Bad input throws `invalidInput` with per-field errors.
    public func jobsSubmit(_ request: SubmitRequest) throws -> JobView {
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
            do { step.inputs = try task.validated(inputs: s.inputs, chained: i > 0, prefix: "\(prefix).inputs") } catch { if case .invalidInput(let e) = error { errors += e } }
            checked.append((step, task))
        }
        if !errors.isEmpty { throw LiftError.invalidInput(errors) }

        let id = UUID().uuidString.lowercased()
        let now = Date()
        var steps: [StepRecord] = []
        for (i, (s, task)) in checked.enumerated() {
            var inputs: [String: String] = [:]
            for input in task.inputs {
                guard let value = s.inputs[input.name] else { continue }
                if input.type == .text { inputs[input.name] = value; continue }
                let source = URL(filePath: value)
                let dest = jobsDir.appending(path: "\(id)/inputs/\(i)-\(input.name)/\(source.lastPathComponent)")
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: dest)
                inputs[input.name] = dest.path
            }
            steps.append(StepRecord(jobId: id, idx: i, recipe: s.recipe, task: s.task, inputs: inputs, settings: s.settings,
                                    state: .queued, outputs: []))
        }
        let firstInput = request.steps[0].inputs.values.first.map { URL(filePath: $0).deletingPathExtension().lastPathComponent }
        try store.db.write { db in
            let position = (try Double.fetchOne(db, sql: "SELECT MAX(position) FROM job") ?? 0) + 1
            let job = JobRecord(id: id, title: request.title ?? firstInput ?? request.steps[0].recipe, priority: request.priority,
                                position: position, source: request.source, state: .queued, forceStart: false, currentStep: 0,
                                createdAt: now, updatedAt: now)
            try job.insert(db)
            for step in steps { try step.insert(db) }
            var e = EventRecord(id: nil, jobId: id, stepIdx: nil, at: now, kind: "state", detail: "queued")
            try e.insert(db)
        }
        tick()
        return try view(id)
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
                    if v.job.state.isTerminal { return v }
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

    /// Queued, waiting or interrupted jobs are cancelled at once. A running job needs `confirm`:
    /// with concurrency 1 its worker is stopped; otherwise the job is marked cancelled and its result discarded.
    public func jobsCancel(_ id: String, confirm: Bool = false) throws -> Gated<JobView> {
        let v = try view(id)
        guard !v.job.state.isTerminal else { throw LiftError.invalidState("job \(id) already \(v.job.state.rawValue)") }
        let step = v.steps[v.job.currentStep]
        if v.job.state.isActive {
            guard confirm else { return .confirmationRequired("Job \"\(v.job.title)\" is \(v.job.state.rawValue); cancelling stops its work and discards any result.") }
            try store.db.write { db in try self.setState(db, job: v.job, step: step, .cancelled) }
            if let w = workers.values.first(where: { $0.assigned[id] != nil }) {
                if w.capacity == 1 {
                    w.stopping = true
                    w.process.kill()
                } else {
                    w.process.send(.cancel(job: id))
                }
            }
        } else {
            try store.db.write { db in try self.setState(db, job: v.job, step: step, .cancelled) }
        }
        tick()
        return .done(try view(id))
    }

    /// Re-queues a finished job from its first unfinished step (all steps if it succeeded).
    /// `settings` replaces that step's settings (validated) when given.
    public func jobsRetry(_ id: String, settings: [String: SettingValue]? = nil) throws -> JobView {
        let v = try view(id)
        guard v.job.state.isTerminal || v.job.state == .interrupted else { throw LiftError.invalidState("job \(id) is \(v.job.state.rawValue); only finished jobs can be retried") }
        let from = v.steps.firstIndex { $0.state != .succeeded } ?? 0
        var newSettings: [String: SettingValue]?
        if let settings {
            let s = v.steps[from]
            guard let task = recipe(s.recipe)?.task(s.task) else { throw LiftError.notFound("recipe \(s.recipe)") }
            newSettings = try task.validated(settings: settings, prefix: "settings")
        }
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
            job.error = nil
            job.finishedAt = nil
            try self.setState(db, job: job, step: nil, .queued)
        }
        tick()
        return try view(id)
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
                           running: workers.values.reduce(0) { $0 + $1.assigned.count }, jobs: order)
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
