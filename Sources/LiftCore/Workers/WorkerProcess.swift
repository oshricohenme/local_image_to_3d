import Foundation
import Subprocess
import Synchronization
import System

/// One running `python -m lift_worker` process. Ops go in through `send`; everything that comes out
/// (`.started(pid)`, protocol events, stderr lines, `.exited`) arrives on `events`, which finishes after `.exited`.
public final class WorkerProcess: Sendable {
    public let events: AsyncStream<WorkerEvent>
    private let ops: AsyncStream<String>.Continuation
    private let task: Task<Void, Never>
    private let pid = PID()

    private final class PID: Sendable {
        let value = Mutex<pid_t>(0)
    }

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String?) {
        let (events, eventsOut) = AsyncStream.makeStream(of: WorkerEvent.self)
        let (opsIn, ops) = AsyncStream.makeStream(of: String.self)
        self.events = events
        self.ops = ops
        var overrides: [Environment.Key: String?] = [:]
        for (k, v) in environment { overrides[Environment.Key(rawValue: k)!] = v }
        let env = Environment.inherit.updating(overrides)
        var options = PlatformOptions()
        options.processGroupID = 0  // its own process group (pgid = pid), so kill() takes grandchildren too
        let pid = self.pid
        task = Task {
            var code: Int32
            do {
                let result = try await Subprocess.run(
                    .path(FilePath(executable)),
                    arguments: Arguments(arguments),
                    environment: env,
                    workingDirectory: workingDirectory.map { FilePath($0) },
                    platformOptions: options,
                    input: .inputWriter,
                    output: .sequence,
                    error: .sequence
                ) { execution in
                    pid.value.withLock { $0 = execution.processIdentifier.value }
                    eventsOut.yield(.started(pid: execution.processIdentifier.value))
                    async let stderr: Void = {
                        for try await line in execution.standardError.strings(bufferingPolicy: .unbounded) {
                            eventsOut.yield(.stderr(line))
                        }
                    }()
                    async let writer: Void = {
                        for await line in opsIn {
                            _ = try await execution.standardInputWriter.write(line)
                        }
                        try await execution.standardInputWriter.finish()
                    }()
                    for try await line in execution.standardOutput.strings(bufferingPolicy: .unbounded) {
                        eventsOut.yield(WorkerEvent.decode(line))
                    }
                    ops.finish()  // stdout closed: the process is going away
                    try? await writer
                    try? await stderr
                }
                code = result.terminationStatus.code
            } catch {
                code = 128 + SIGKILL  // cancelled before start: swift-subprocess tears it down with SIGKILL
            }
            pid.value.withLock { $0 = 0 }  // never signal a reused pid
            eventsOut.yield(.exited(code))
            eventsOut.finish()
        }
    }

    public func send(_ op: WorkerOp) {
        ops.yield(op.line)
    }

    /// Stops the process and everything it started (its process group) now with SIGKILL, even if it is stuck
    /// in native code.
    public func kill() {
        let p = pid.value.withLock { $0 }
        if p > 0 {
            Darwin.kill(-p, SIGKILL)
            Darwin.kill(p, SIGKILL)
        } else {
            task.cancel()
        }
    }
}
