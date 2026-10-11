import Foundation
import LiftCore

/// The JSON both adapters speak: LiftCore's Codable types with snake_case keys and ISO 8601 dates.
/// Dictionary keys (setting keys, input names) are left alone by the key strategy.
enum Wire {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// For openapi.yaml's generated types (their coding keys are already snake_case) and for `SubmitWire`.
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func data(_ value: some Encodable) throws -> Data { try encoder.encode(value) }

    /// LiftCore value → a generated OpenAPI type (or the reverse) through the wire JSON.
    static func convert<T: Decodable>(_ value: some Encodable, to _: T.Type = T.self) throws -> T {
        try decoder.decode(T.self, from: data(value))
    }
}

/// One output file, by path (this Mac), MCP resource URI and HTTP path (spec §10: outputs as paths and URIs).
struct OutputFile: Codable, Sendable, Equatable {
    var path: String
    var uri: String
    var url: String

    init(job: String, path: String) {
        let name = path.split(separator: "/").last.map(String.init) ?? path  // not URL: it may decompose accents
        let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? name
        self.path = path
        uri = "lift://jobs/\(job)/outputs/\(escaped)"
        url = "/v1/jobs/\(job)/outputs/\(escaped)"
    }
}

/// `JobView` plus its outputs (JobView.outputs is computed, so it isn't encoded by itself).
struct JobOut: Encodable, Sendable {
    var job: JobRecord
    var steps: [StepRecord]
    var attribution: Attribution?
    var outputs: [OutputFile]

    init(_ v: JobView) {
        job = v.job
        steps = v.steps
        attribution = v.attribution
        outputs = v.outputs.map { OutputFile(job: v.job.id, path: $0) }
    }
}

struct JobListOut: Encodable { var jobs: [JobOut] }

struct QueueOut: Encodable {
    var paused: Bool
    var maxSlots: Int
    var running: Int
    var jobs: [JobOut]

    init(_ q: QueueStatus) {
        paused = q.paused
        maxSlots = q.maxSlots
        running = q.running
        jobs = q.jobs.map(JobOut.init)
    }
}

struct ModelListOut: Encodable { var models: [ModelView] }
struct WorkerListOut: Encodable { var workers: [WorkerView] }
struct UninstalledOut: Encodable { var model: ModelView? }
struct DeletedOut: Encodable { var deleted: Bool }

extension JobView {
    /// The step output named `file` (the last step that has one wins).
    func output(named file: String) -> String? {
        steps.reversed().lazy.flatMap(\.outputs).first { URL(filePath: $0).lastPathComponent == file }
    }
}

/// LiftCore's settings and the server's, as one object.
struct SettingsOut: Encodable {
    var core: Settings
    var server: ServerSettings

    func encode(to encoder: any Encoder) throws {
        try core.encode(to: encoder)
        try server.encode(to: encoder)  // same object: JSONEncoder merges keyed containers
    }
}

struct RecipesOut: Encodable { var recipes: [RecipeListing] }

/// What `jobs_submit` / `jobs_retry` answer when the job is too big for this Mac (spec §8). Nothing was queued.
struct MemoryWarningOut: Encodable {
    var memoryWarning: MemoryWarning
    var hint = "Nothing was queued. Call again with accept_memory_warning: true to run it anyway."
}
