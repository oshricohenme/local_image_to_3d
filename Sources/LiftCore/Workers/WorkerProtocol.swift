import Foundation

/// App → worker messages (protocol v1, spec §8).
public enum WorkerOp: Sendable, Equatable {
    case run(job: String, step: Int, task: String, inputs: [String: String], settings: [String: SettingValue], outDir: String)
    case shutdown

    /// One JSON line, newline included.
    public var line: String {
        var object: [String: AnyEncodable] = [:]
        switch self {
        case .run(let job, let step, let task, let inputs, let settings, let outDir):
            object = ["op": .init("run"), "job": .init(job), "step": .init(step), "task": .init(task),
                      "inputs": .init(inputs), "settings": .init(settings), "out_dir": .init(outDir)]
        case .shutdown:
            object = ["op": .init("shutdown")]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(object), as: UTF8.self) + "\n"
    }
}

struct AnyEncodable: Encodable {
    let value: any Encodable & Sendable
    init(_ value: any Encodable & Sendable) { self.value = value }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

/// Worker → app messages, plus what the process itself does (start, stderr lines, exit).
public enum WorkerEvent: Sendable, Equatable {
    case started(pid: Int32)
    case ready(protocol: Int, loadSeconds: Double)
    case log(job: String, line: String)
    case stage(job: String, name: String, fraction: Double?)
    case done(job: String, outputs: [String])
    /// `job == nil`: the launcher failed to load; the worker exits.
    case error(job: String?, message: String, traceback: String?)
    case heartbeat(mpsAllocated: Int)
    case stderr(String)
    /// A protocol line that isn't valid JSON or isn't a known event.
    case malformed(String)
    case exited(Int32)

    public static func decode(_ line: String) -> WorkerEvent {
        struct Raw: Decodable {
            var ev: String
            var `protocol`: Int?
            var load_seconds: Double?
            var job: String?
            var line: String?
            var name: String?
            var fraction: Double?
            var outputs: [String]?
            var message: String?
            var traceback: String?
            var mps_allocated: Int?
        }
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(line.utf8)) else { return .malformed(line) }
        switch raw.ev {
        case "ready": return .ready(protocol: raw.protocol ?? 0, loadSeconds: raw.load_seconds ?? 0)
        case "log": if let j = raw.job, let l = raw.line { return .log(job: j, line: l) }
        case "stage": if let j = raw.job, let n = raw.name { return .stage(job: j, name: n, fraction: raw.fraction) }
        case "done": if let j = raw.job { return .done(job: j, outputs: raw.outputs ?? []) }
        case "error": return .error(job: raw.job, message: raw.message ?? "unknown error", traceback: raw.traceback)
        case "heartbeat": return .heartbeat(mpsAllocated: raw.mps_allocated ?? 0)
        default: break
        }
        return .malformed(line)
    }
}
