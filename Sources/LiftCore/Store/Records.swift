import Foundation
import GRDB

public enum JobState: String, Codable, Sendable, CaseIterable {
    case queued, waiting, loading, running, succeeded, failed, cancelled, interrupted

    public var isTerminal: Bool { self == .succeeded || self == .failed || self == .cancelled }
    public var isActive: Bool { self == .loading || self == .running }
}

public enum Priority: String, Codable, Sendable, CaseIterable {
    case low, normal, high

    public var rank: Int {
        switch self {
        case .low: 0
        case .normal: 1
        case .high: 2
        }
    }
}

public enum JobSource: String, Codable, Sendable {
    case ui, http, mcp
}

/// Why a step is not running. Facts only; encoded as `{"reason": "memory", "needed": …, "free": …}`.
public enum WaitReason: Codable, Sendable, Equatable {
    case noFreeSlot
    case memory(needed: Int, free: Int)
    case modelInstalling
    case modelNotInstalled
    case modelUnsupported
    case weightsUnverified
    case queuePaused

    private enum CodingKeys: String, CodingKey { case reason, needed, free }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .reason) {
        case "no_free_slot": self = .noFreeSlot
        case "memory": self = .memory(needed: try c.decode(Int.self, forKey: .needed), free: try c.decode(Int.self, forKey: .free))
        case "model_installing": self = .modelInstalling
        case "model_not_installed": self = .modelNotInstalled
        case "model_unsupported": self = .modelUnsupported
        case "weights_unverified": self = .weightsUnverified
        case "queue_paused": self = .queuePaused
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .reason, in: c, debugDescription: "unknown wait reason \(other)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noFreeSlot: try c.encode("no_free_slot", forKey: .reason)
        case .memory(let needed, let free):
            try c.encode("memory", forKey: .reason)
            try c.encode(needed, forKey: .needed)
            try c.encode(free, forKey: .free)
        case .modelInstalling: try c.encode("model_installing", forKey: .reason)
        case .modelNotInstalled: try c.encode("model_not_installed", forKey: .reason)
        case .modelUnsupported: try c.encode("model_unsupported", forKey: .reason)
        case .weightsUnverified: try c.encode("weights_unverified", forKey: .reason)
        case .queuePaused: try c.encode("queue_paused", forKey: .reason)
        }
    }
}

public struct JobRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "job"
    public var id: String
    public var title: String
    public var priority: Priority
    /// Manual order within a priority. Set to max + 1 on submit; `jobs_move` renumbers.
    public var position: Double
    public var source: JobSource
    public var state: JobState
    public var waitReason: WaitReason?
    public var forceStart: Bool
    /// Index of the step that runs next (or ran last).
    public var currentStep: Int
    public var error: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
}

public struct StepRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "step"
    public var jobId: String
    public var idx: Int
    public var recipe: String
    public var task: String
    /// Input name → absolute path inside `jobs/<id>/inputs/` (or the text itself for `text` inputs).
    /// A chained step's first input is filled from the previous step's first output when it starts.
    public var inputs: [String: String]
    public var settings: [String: SettingValue]
    public var state: JobState
    public var waitReason: WaitReason?
    public var stage: String?
    public var fraction: Double?
    public var outputs: [String]
    public var error: String?
    public var workerId: String?
    public var startedAt: Date?
    public var finishedAt: Date?
}

public struct EventRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "event"
    public var id: Int64?
    public var jobId: String
    public var stepIdx: Int?
    public var at: Date
    /// `state` for now; `detail` is the new state, its wait reason and any error.
    public var kind: String
    public var detail: String

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct WorkerRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "worker"
    public var id: String
    public var recipe: String
    public var pid: Int32
    public var startedAt: Date
    public var loadSeconds: Double?
    public var endedAt: Date?
    public var endReason: String?
}

public struct MemorySampleRecord: Codable, Sendable, Equatable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "memorySample"
    public enum Kind: String, Codable, Sendable { case load, job }
    public var id: Int64?
    public var recipe: String
    public var task: String
    /// Canonical JSON of the recipe's `memory_keys` values, e.g. `{"low_vram":true}`.
    public var keyValues: String
    public var kind: Kind
    public var bytes: Int
    public var at: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

public struct SettingRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "setting"
    public var key: String
    /// JSON text of the value.
    public var value: String
}
