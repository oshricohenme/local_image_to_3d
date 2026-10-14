import Foundation

/// One problem with one field of a request, e.g. `steps[0].settings.size`.
public struct FieldError: Codable, Sendable, Equatable {
    public var field: String
    public var message: String
    public init(_ field: String, _ message: String) {
        self.field = field
        self.message = message
    }
}

public enum LiftError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case invalidInput([FieldError])
    case invalidState(String)
    case prerequisite(String)
    /// A shell command failed: the exact command and the end of its output.
    case commandFailed(command: String, exitCode: Int32, tail: [String])

    public var description: String {
        switch self {
        case .notFound(let what): "not found: \(what)"
        case .invalidInput(let errors): "invalid input: " + errors.map { "\($0.field): \($0.message)" }.joined(separator: "; ")
        case .invalidState(let why): why
        case .prerequisite(let why): why
        case .commandFailed(let command, let code, let tail):
            "`\(command)` failed with exit code \(code)\n" + tail.joined(separator: "\n")
        }
    }
}
