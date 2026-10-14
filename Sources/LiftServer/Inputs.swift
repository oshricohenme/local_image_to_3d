import Foundation
import LiftCore

/// `jobs_submit` as HTTP and MCP callers send it (openapi.yaml `SubmitJob`).
struct SubmitWire: Codable, Sendable {
    struct Step: Codable, Sendable {
        var recipe: String
        var task: String
        var inputs: [String: String]?
        var settings: [String: SettingValue]?
    }

    var steps: [Step]
    var title: String?
    var priority: Priority?
    /// Run even if the job is bigger than this Mac's memory or the budget (spec §8).
    var acceptMemoryWarning: Bool?
    var export: Export?

    /// `ExportSpec` on the wire (snake_case).
    struct Export: Codable, Sendable {
        var dir: String?
        var formats: [ExportFormat]?
        var cleanupAfterExport: Bool?
        enum CodingKeys: String, CodingKey { case dir, formats, cleanupAfterExport = "cleanup_after_export" }
    }

    enum CodingKeys: String, CodingKey { case steps, title, priority, acceptMemoryWarning = "accept_memory_warning", export }
}

/// Turns `<name>`, `<name>_path`, `<name>_base64` (+ `<name>_filename`) and multipart uploads into the
/// plain paths `Lift.jobsSubmit` takes. Decoded files go to `<workdir>/uploads/<uuid>/`; the caller removes
/// that folder after submitting (jobsSubmit has copied them into the job by then).
struct Inputs {
    let uploads: URL

    init(workdir: URL) {
        uploads = workdir.appending(path: "uploads/\(UUID().uuidString)")
    }

    /// `files`: multipart parts by name (`steps[0].image`) → the saved file.
    func resolve(_ wire: SubmitWire, files: [String: URL] = [:], source: JobSource) throws -> SubmitRequest {
        var errors: [FieldError] = []
        var steps: [StepRequest] = []
        var parts: [Int: [(name: String, url: URL)]] = [:]
        for (part, url) in files.sorted(by: { $0.key < $1.key }) {
            guard let m = part.wholeMatch(of: /steps\[(\d+)\]\.(\w+)/), let i = Int(m.1), i < wire.steps.count else {
                errors.append(FieldError(part, "file parts are named steps[<i>].<input>"))
                continue
            }
            parts[i, default: []].append((String(m.2), url))
        }
        for (i, step) in wire.steps.enumerated() {
            var inputs: [String: String] = [:]
            let given = step.inputs ?? [:]
            func set(_ name: String, _ value: String, _ key: String) {
                if inputs[name] != nil {
                    errors.append(FieldError("steps[\(i)].inputs.\(key)", "\(name) is given more than once"))
                } else {
                    inputs[name] = value
                }
            }
            for (key, value) in given.sorted(by: { $0.key < $1.key }) {
                if key.hasSuffix("_filename") {
                    let name = String(key.dropLast("_filename".count))
                    if given["\(name)_base64"] == nil { errors.append(FieldError("steps[\(i)].inputs.\(key)", "only goes with \(name)_base64")) }
                } else if key.hasSuffix("_path") {
                    set(String(key.dropLast("_path".count)), value, key)
                } else if key.hasSuffix("_base64") {
                    let name = String(key.dropLast("_base64".count))
                    // The name becomes a folder under uploads/: letters, digits and _ only, so it can't climb out.
                    guard name.wholeMatch(of: /[A-Za-z0-9_]+/) != nil else {
                        errors.append(FieldError("steps[\(i)].inputs.\(key)", "input names use only letters, digits and _"))
                        continue
                    }
                    guard let data = Data(base64Encoded: value, options: .ignoreUnknownCharacters), !data.isEmpty else {
                        errors.append(FieldError("steps[\(i)].inputs.\(key)", "is not valid base64"))
                        continue
                    }
                    let filename = URL(filePath: given["\(name)_filename"] ?? name).lastPathComponent
                    do {
                        set(name, try save(data, step: i, name: name, filename: filename).path, key)
                    } catch {
                        errors.append(FieldError("steps[\(i)].inputs.\(key)", "could not be saved: \(error)"))
                    }
                } else {
                    set(key, value, key)
                }
            }
            for (name, url) in parts[i] ?? [] { set(name, url.path, name) }
            steps.append(StepRequest(recipe: step.recipe, task: step.task, inputs: inputs, settings: step.settings ?? [:]))
        }
        if !errors.isEmpty
 { throw LiftError.invalidInput(errors) }
        return SubmitRequest(steps: steps, title: wire.title, priority: wire.priority ?? .normal, source: source,
                             export: wire.export.map { ExportSpec(dir: $0.dir, formats: $0.formats, cleanupAfterExport: $0.cleanupAfterExport) })
    }

    func save(_ data: Data, step: Int, name: String, filename: String) throws -> URL {
        let url = uploads.appending(path: "\(step)-\(name)/\(filename)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    /// A multipart part's file: written as it streams in.
    func file(part: String, filename: String?) throws -> URL {
        let url = uploads.appending(path: "parts/\(UUID().uuidString)/\(URL(filePath: filename ?? part).lastPathComponent)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    func cleanUp() { try? FileManager.default.removeItem(at: uploads) }
}
