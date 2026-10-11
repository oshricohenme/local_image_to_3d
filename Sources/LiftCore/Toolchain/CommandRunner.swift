import Foundation
import Subprocess
import System

/// One external command. Install steps are `/bin/sh -c <step>`.
public struct ShellCommand: Sendable, Equatable {
    public var executable: String
    public var arguments: [String]
    /// Overrides on top of the inherited environment.
    public var environment: [String: String]
    public var workingDirectory: String?

    public init(_ executable: String, _ arguments: [String] = [], environment: [String: String] = [:], workingDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// What logs and errors show.
    public var display: String {
        if executable == "/bin/sh", arguments.first == "-c", arguments.count == 2 { return arguments[1] }
        return ([executable] + arguments).joined(separator: " ")
    }
}

/// Runs commands; injectable so tests never install anything.
public protocol CommandRunner: Sendable {
    /// Runs to completion, streaming stdout and stderr merged, line by line. Returns the exit code
    /// (128 + signal when killed).
    func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32
}

extension CommandRunner {
    /// Runs and throws `LiftError.commandFailed` with the last 40 lines on a non-zero exit.
    public func check(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let tail = Tail(limit: 40)
        let code = try await run(command) { line in
            tail.append(line)
            onLine(line)
        }
        if code != 0 { throw LiftError.commandFailed(command: command.display, exitCode: code, tail: tail.lines) }
    }

    /// Runs and returns the whole output, or throws on a non-zero exit.
    public func output(_ command: ShellCommand) async throws -> String {
        let all = Tail(limit: .max)
        try await check(command) { all.append($0) }
        return all.lines.joined(separator: "\n")
    }
}

/// The real runner, on swift-subprocess.
public struct SubprocessRunner: CommandRunner {
    public init() {}

    public func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        var overrides: [Environment.Key: String?] = [:]
        for (k, v) in command.environment { overrides[Environment.Key(rawValue: k)!] = v }
        let result = try await Subprocess.run(
            .path(FilePath(command.executable)),
            arguments: Arguments(command.arguments),
            environment: .inherit.updating(overrides),
            workingDirectory: command.workingDirectory.map { FilePath($0) },
            input: .none,
            output: .sequence,
            error: .combinedWithOutput
        ) { execution in
            for try await line in execution.standardOutput.strings(bufferingPolicy: .unbounded) {
                onLine(line)
            }
        }
        return result.terminationStatus.code
    }
}
