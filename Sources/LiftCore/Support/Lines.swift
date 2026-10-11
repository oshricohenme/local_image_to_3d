import Foundation
import Subprocess
import Synchronization

/// A thread-safe ring of the last `limit` lines.
public final class Tail: Sendable {
    private let state: Mutex<[String]>
    private let limit: Int

    public init(limit: Int) {
        self.limit = limit
        state = Mutex([])
    }

    public func append(_ line: String) {
        state.withLock { lines in
            lines.append(line)
            if lines.count > limit { lines.removeFirst(lines.count - limit) }
        }
    }

    public var lines: [String] { state.withLock { $0 } }
}

/// Appends lines to a file (created if missing); thread-safe.
public final class LogFile: Sendable {
    private let handle: Mutex<FileHandle>

    public init(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        handle = Mutex(h)
    }

    public func write(_ line: String) {
        handle.withLock { _ = try? $0.write(contentsOf: Data((line + "\n").utf8)) }
    }
}

extension TerminationStatus {
    /// The exit code, or 128 + signal like a shell.
    var code: Int32 {
        switch self {
        case .exited(let c): c
        case .signaled(let s): 128 + s
        }
    }
}
