import Foundation

/// What one step needs, in bytes (spec §8 "Memory estimates").
public struct MemoryNeed: Sendable, Equatable {
    /// Loading the model in a new worker.
    public var load: Int
    /// One job's working memory on top of a loaded model.
    public var job: Int
    public var newWorker: Int { load + job }
}

/// How a candidate's model stands, as far as starting it goes. `weightsUnverified`: installed, but a new
/// worker would be needed and its weights haven't passed verification for that start.
public enum ModelReadiness: Sendable, Equatable {
    case ready, installing, notInstalled, unsupported, weightsUnverified
}

/// A job whose current step could start.
public struct Candidate: Sendable, Equatable {
    public var jobId: String
    public var recipe: String
    public var priority: Priority
    public var position: Double
    public var createdAt: Date
    public var forceStart: Bool
    public var model: ModelReadiness
    public var need: MemoryNeed
    /// The caller accepted a memory warning for this job.
    public var memoryAccepted: Bool

    public init(jobId: String, recipe: String, priority: Priority = .normal, position: Double, createdAt: Date = Date(timeIntervalSince1970: 0),
                forceStart: Bool = false, model: ModelReadiness = .ready, need: MemoryNeed, memoryAccepted: Bool = false) {
        self.memoryAccepted = memoryAccepted
        self.jobId = jobId
        self.recipe = recipe
        self.priority = priority
        self.position = position
        self.createdAt = createdAt
        self.forceStart = forceStart
        self.model = model
        self.need = need
    }
}

public struct WorkerSnapshot: Sendable, Equatable {
    public var recipe: String
    /// `max_concurrent_per_process` minus steps on it.
    public var freeCapacity: Int
    /// Bytes this worker holds: max(measured footprint, baseline + running claims).
    public var reserved: Int

    public init(recipe: String, freeCapacity: Int, reserved: Int) {
        self.recipe = recipe
        self.freeCapacity = freeCapacity
        self.reserved = reserved
    }
}

public struct SchedulerInput: Sendable {
    public var candidates: [Candidate]
    public var workers: [WorkerSnapshot]
    public var runningSteps: Int
    public var maxSlots: Int
    public var budget: Int
    public var systemFree: Int
    public var physical: Int
    public var paused: Bool

    public init(candidates: [Candidate], workers: [WorkerSnapshot] = [], runningSteps: Int = 0, maxSlots: Int = 1,
                budget: Int, systemFree: Int, physical: Int = .max, paused: Bool = false) {
        self.physical = physical
        self.candidates = candidates
        self.workers = workers
        self.runningSteps = runningSteps
        self.maxSlots = maxSlots
        self.budget = budget
        self.systemFree = systemFree
        self.paused = paused
    }
}

public enum Decision: Sendable, Equatable {
    case start(String)
    case wait(String, WaitReason)
}

/// Pure start decisions (spec §8). Order: priority, then manual position, then submission time.
/// Each candidate is judged on its own, in order, with resources deducted as starts are decided;
/// one that can't start doesn't hold back the ones after it. No reordering by model warmth.
public enum Scheduler {
    public static func order(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.priority.rank != b.priority.rank { return a.priority.rank > b.priority.rank }
        if a.position != b.position { return a.position < b.position }
        return a.createdAt < b.createdAt
    }

    public static func decide(_ input: SchedulerInput) -> [Decision] {
        var slots = input.maxSlots - input.runningSteps
        var reserved = input.workers.reduce(0) { $0 + $1.reserved }
        var systemFree = input.systemFree
        var capacity = input.workers.map { ($0.recipe, $0.freeCapacity) }
        var startedHere = 0
        var out: [Decision] = []
        for c in input.candidates.sorted(by: order) {
            if input.paused { out.append(.wait(c.jobId, .queuePaused)); continue }
            switch c.model {
            case .installing: out.append(.wait(c.jobId, .modelInstalling)); continue
            case .notInstalled: out.append(.wait(c.jobId, .modelNotInstalled)); continue
            case .unsupported: out.append(.wait(c.jobId, .modelUnsupported)); continue
            case .weightsUnverified: out.append(.wait(c.jobId, .weightsUnverified)); continue
            case .ready: break
            }
            guard slots > 0 else { out.append(.wait(c.jobId, .noFreeSlot)); continue }
            let shared = capacity.firstIndex { $0.0 == c.recipe && $0.1 > 0 }
            let needed = shared == nil ? c.need.newWorker : c.need.job
            let budgetFree = input.budget - reserved
            // An accepted too-big job (over the budget or this Mac's RAM) can never fit, so it starts when the
            // machine is otherwise idle, skipping the memory checks; until then it waits like any other.
            let tooBig = c.memoryAccepted && (needed > input.budget || needed > input.physical)
            let idle = input.runningSteps == 0 && startedHere == 0
            if !c.forceStart && !(tooBig && idle) && (tooBig || needed > budgetFree || needed > systemFree) {
                out.append(.wait(c.jobId, .memory(needed: needed, free: max(0, min(budgetFree, systemFree)))))
                continue
            }
            out.append(.start(c.jobId))
            startedHere += 1
            slots -= 1
            reserved += needed
            systemFree -= needed
            if let shared { capacity[shared].1 -= 1 }
        }
        return out
    }
}
