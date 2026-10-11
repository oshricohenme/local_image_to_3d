import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// Records commands and answers from a script: the first rule whose `match` is contained in the
/// command's display string decides the exit code and output lines. Unmatched commands succeed silently.
final class FakeRunner: CommandRunner {
    struct Rule: Sendable {
        var match: String
        var code: Int32
        var lines: [String]
        var effect: (@Sendable () -> Void)?
    }

    private let state = Mutex<(commands: [ShellCommand], rules: [Rule])>(([], []))

    /// `effect` runs when the rule matches (e.g. to break something mid-install).
    func on(_ match: String, code: Int32 = 0, lines: [String] = [], effect: (@Sendable () -> Void)? = nil) {
        state.withLock { $0.rules.append(Rule(match: match, code: code, lines: lines, effect: effect)) }
    }

    var commands: [ShellCommand] { state.withLock { $0.commands } }
    var displays: [String] { commands.map(\.display) }

    func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let rule = state.withLock { s -> Rule? in
            s.commands.append(command)
            return s.rules.first { command.display.contains($0.match) }
        }
        rule?.effect?()
        for line in rule?.lines ?? [] { onLine(line) }
        if (rule?.code ?? 0) == 0, command.arguments.contains("clone"), let dest = command.arguments.last {
            try FileManager.default.createDirectory(atPath: dest + "/.git", withIntermediateDirectories: true)  // like git would
        }
        return rule?.code ?? 0
    }
}

extension Fixtures {
    /// A uv-managed Python 3.11 (uv downloads it if missing).
    static func python() async throws -> String {
        let uv = try #require(Toolchain(runner: SubprocessRunner()).find("uv"), "uv must be installed")
        return try await SubprocessRunner().output(ShellCommand(uv, ["python", "find", "3.11"])).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
