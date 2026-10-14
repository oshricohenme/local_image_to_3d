import Foundation

/// "Too big for this Mac" (spec §8): a step's memory estimate is above this Mac's physical RAM or the
/// memory budget. A warning, never a refusal: the caller repeats the call with `acceptMemoryWarning: true`.
public struct MemoryWarning: Codable, Sendable, Equatable {
    public var message: String
    public var neededGB: Double
    public var physicalGB: Double
    public var budgetGB: Double
    /// Index of the first step that is too big.
    public var step: Int
}

/// The result of `jobs_submit` / `jobs_retry`: independent of `Gated`/confirm.
public enum Admission<T: Sendable>: Sendable {
    case accepted(T)
    /// Nothing was changed.
    case memoryWarning(MemoryWarning)

    public var value: T? {
        if case .accepted(let v) = self { v } else { nil }
    }

    public var warning: MemoryWarning? {
        if case .memoryWarning(let w) = self { w } else { nil }
    }
}
