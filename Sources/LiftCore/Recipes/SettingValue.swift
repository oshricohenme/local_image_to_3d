import Foundation

/// A setting value: from recipe YAML, from a request (JSON), or stored in a step.
public enum SettingValue: Codable, Sendable, Hashable, CustomStringConvertible {
    case bool(Bool)
    case int(Int)
    case float(Double)
    case string(String)

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int.self) { self = .int(v) }
        else if let v = try? c.decode(Double.self) { self = .float(v) }
        else { self = .string(try c.decode(String.self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .float(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        }
    }

    public var description: String {
        switch self {
        case .bool(let v): "\(v)"
        case .int(let v): "\(v)"
        case .float(let v): "\(v)"
        case .string(let v): v
        }
    }

    /// Numeric view for min/max checks and loose enum matching (1024 == 1024.0).
    var number: Double? {
        switch self {
        case .int(let v): Double(v)
        case .float(let v): v
        default: nil
        }
    }
}
