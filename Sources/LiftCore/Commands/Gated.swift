import Foundation

/// The result of a risky command (spec §10). Without `confirm: true` it changes nothing and
/// returns `confirmationRequired` with a description of the impact.
public enum Gated<T: Sendable>: Sendable {
    case done(T)
    case confirmationRequired(String)

    public var value: T? {
        if case .done(let v) = self { v } else { nil }
    }

    public var impact: String? {
        if case .confirmationRequired(let s) = self { s } else { nil }
    }
}
