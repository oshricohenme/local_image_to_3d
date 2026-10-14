import Foundation
import GRDB
import LiftCore
import MCP
import UniformTypeIdentifiers

/// MCP resources (spec §10): `lift://jobs/{id}` (JSON), `lift://jobs/{id}/outputs/{file}` (the file),
/// `lift://models/{id}/install-log` (text) and `lift://resources` (JSON). Jobs and resources can be subscribed to.
enum Resources {
    static let fixed = [Resource(name: "resources", uri: "lift://resources", description: "Slots, memory budget, workers and learned estimates.",
                                 mimeType: "application/json")]

    static let templates = [
        Resource.Template(uriTemplate: "lift://jobs/{id}", name: "job", description: "A job with its steps and outputs; subscribe for updates.", mimeType: "application/json"),
        Resource.Template(uriTemplate: "lift://jobs/{id}/outputs/{file}", name: "job output", description: "One output file of a job."),
        Resource.Template(uriTemplate: "lift://models/{id}/install-log", name: "install log", description: "A model's install.log.", mimeType: "text/plain"),
    ]

    enum Target: Equatable {
        case job(String)
        case output(job: String, file: String)
        case installLog(String)
        case resources
    }

    static func parse(_ uri: String) -> Target? {
        guard uri.hasPrefix("lift://") else { return nil }
        let parts = uri.dropFirst("lift://".count).split(separator: "/", omittingEmptySubsequences: false).map { $0.removingPercentEncoding ?? String($0) }
        switch parts.count {
        case 1 where parts[0] == "resources": return .resources
        case 2 where parts[0] == "jobs": return .job(parts[1])
        case 3 where parts[0] == "models" && parts[2] == "install-log": return .installLog(parts[1])
        case 4 where parts[0] == "jobs" && parts[2] == "outputs": return .output(job: parts[1], file: parts[3])
        default: return nil
        }
    }

    static func mimeType(_ path: String) -> String {
        UTType(filenameExtension: URL(filePath: path).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }

    static func read(_ uri: String, lift: Lift) async throws -> [Resource.Content] {
        switch parse(uri) {
        case .resources:
            return [.text(String(decoding: try Wire.data(try await lift.resourcesGet()), as: UTF8.self), uri: uri, mimeType: "application/json")]
        case .job(let id):
            return [.text(String(decoding: try Wire.data(JobOut(try await lift.jobsGet(id))), as: UTF8.self), uri: uri, mimeType: "application/json")]
        case .installLog(let id):
            return [.text(try await lift.modelsInstallLog(id), uri: uri, mimeType: "text/plain")]
        case .output(let job, let file):
            let url = try await Shared(lift: lift).output(job, file: file)
            return [.binary(try Data(contentsOf: url), uri: uri, mimeType: mimeType(url.path))]
        case nil:
            throw MCPError.invalidParams("unknown resource \(uri)")
        }
    }
}

/// One session's subscriptions. Each is a task that sends `notifications/resources/updated`.
actor Subscriptions {
    let lift: Lift
    var tasks: [String: Task<Void, Never>] = [:]

    init(lift: Lift) { self.lift = lift }

    func subscribe(_ uri: String, notify: @escaping @Sendable (String) async -> Void) throws {
        guard tasks[uri] == nil else { return }
        let lift = self.lift
        switch Resources.parse(uri) {
        case .job(let id):
            tasks[uri] = Task {
                var first = true
                do {
                    for try await _ in Self.changes(of: id, in: lift.store) {
                        if first { first = false } else { await notify(uri) }
                    }
                } catch {}
            }
        case .resources:
            tasks[uri] = Task {
                // ponytail: polls every second; free system memory is left out of the comparison or it would always differ.
                var last: ResourcesView?
                while !Task.isCancelled {
                    if var now = try? await lift.resourcesGet() {
                        now.systemFreeBytes = 0
                        if let last, last != now { await notify(uri) }
                        last = now
                    }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        default:
            throw MCPError.invalidParams("only lift://jobs/{id} and lift://resources can be subscribed to")
        }
    }

    /// The job's rows now, then on every write to them (state, stage, fraction, outputs).
    static func changes(of id: String, in store: Store) -> some AsyncSequence<JobRows, any Error> {
        ValueObservation.tracking { db in
            JobRows(job: try JobRecord.fetchOne(db, key: id), steps: try StepRecord.filter(Column("jobId") == id).fetchAll(db))
        }.removeDuplicates().values(in: store.db)
    }

    struct JobRows: Equatable {
        var job: JobRecord?
        var steps: [StepRecord]
    }

    func unsubscribe(_ uri: String) { tasks.removeValue(forKey: uri)?.cancel() }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
    }
}
