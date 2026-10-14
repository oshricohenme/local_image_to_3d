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
    public init(jobId: String, recipe: String, priority: Priority = .normal, position: Double, createdAt: Date = Date(timeIntervalSince1970: 0),
                forceStart: Bool = false, model: ModelReadiness = .ready, need: MemoryNeed) {
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
    /// 1 when it's idle (one job per worker), else 0.
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
        var capacity = input.workers.map { ($0.recipe, $0.freeCapacity) }
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
            // Memory never holds a job back: macOS swaps past RAM, and idle models in the way are unloaded (keepLoaded).
            let shared = capacity.firstIndex { $0.0 == c.recipe && $0.1 > 0 }
            out.append(.start(c.jobId))
            slots -= 1
            if let shared { capacity[shared].1 -= 1 }
        }
        return out
    }

    /// When a starting job loads a model that doesn't fit beside the idle ones, the models idle workers may keep:
    /// the ones those jobs run. Every other idle worker is unloaded now, not after the idle timeout. nil when it fits.
    public static func keepLoaded(_ input: SchedulerInput, _ decisions: [Decision]) -> Set<String>? {
        let byId = Dictionary(input.candidates.map { ($0.jobId, $0) }, uniquingKeysWith: { a, _ in a })
        let loaded = Set(input.workers.filter { $0.freeCapacity > 0 }.map(\.recipe))
        let free = min(input.budget - input.workers.reduce(0) { $0 + $1.reserved }, input.systemFree)
        let short = decisions.compactMap { d -> String? in
            guard case .start(let id) = d, let c = byId[id], !loaded.contains(c.recipe), c.need.newWorker > free else { return nil }
            return c.recipe
        }
        return short.isEmpty ? nil : Set(short)
    }
}
