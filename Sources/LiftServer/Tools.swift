import Foundation
import LiftCore
import MCP

/// The MCP tools: one per openapi.yaml operation, named by its operationId (spec §10 `area_action`).
/// Arguments are the operation's path and query parameters plus its JSON body's properties.
/// Operations marked `x-mcp: false` (file download) are MCP resources instead.
enum ToolCatalog {
    static let tools: [Tool] = build(try! JSONDecoder().decode(Value.self, from: OpenAPIDocument.json))

    static func build(_ doc: Value) -> [Tool] {
        func resolve(_ node: Value) -> Value {
            switch node {
            case .object(let o):
                if let ref = o["$ref"]?.stringValue {
                    var target = doc
                    for part in ref.split(separator: "/").dropFirst() { target = target.objectValue?[String(part)] ?? .null }
                    return resolve(target)
                }
                return .object(o.mapValues(resolve))
            case .array(let a): return .array(a.map(resolve))
            default: return node
            }
        }
        var tools: [Tool] = []
        for (_, item) in doc.objectValue?["paths"]?.objectValue ?? [:] {
            guard let item = item.objectValue, item["x-mcp"]?.boolValue != false else { continue }
            for method in ["get", "post", "put", "patch", "delete"] {
                guard let op = item[method]?.objectValue, let name = op["operationId"]?.stringValue else { continue }
                var properties: [String: Value] = [:]
                var required: [String] = []
                let parameters = (item["parameters"]?.arrayValue ?? []) + (op["parameters"]?.arrayValue ?? [])
                for p in parameters.compactMap({ resolve($0).objectValue }) {
                    guard let pname = p["name"]?.stringValue else { continue }
                    var schema = p["schema"]?.objectValue ?? [:]
                    if let d = p["description"] { schema["description"] = d }
                    properties[pname] = .object(schema)
                    if p["required"]?.boolValue == true { required.append(pname) }
                }
                if let body = op["requestBody"]?.objectValue,
                   let schema = body["content"]?.objectValue?["application/json"]?.objectValue?["schema"].map(resolve)?.objectValue {
                    for (k, v) in schema["properties"]?.objectValue ?? [:] { properties[k] = v }
                    if body["required"]?.boolValue == true { required += (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue) }
                }
                let description = [op["summary"], op["description"]].compactMap { $0?.stringValue }.joined(separator: "\n\n")
                tools.append(Tool(
                    name: name, description: description,
                    inputSchema: ["type": "object", "properties": .object(properties), "required": .array(required.sorted().map { .string($0) })],
                    annotations: .init(readOnlyHint: method == "get" ? true : nil, destructiveHint: properties["confirm"] != nil ? true : nil)))
            }
        }
        return tools.sorted { $0.name < $1.name }
    }
}

/// A tool call's arguments, with per-field errors like the HTTP adapter's 422.
struct Args {
    let values: [String: Value]

    func decode<T: Decodable>(_ key: String, as _: T.Type = T.self) throws -> T? {
        guard let v = values[key], !v.isNull else { return nil }
        do { return try Wire.decoder.decode(T.self, from: JSONEncoder().encode(v)) } catch {
            throw LiftError.invalidInput([FieldError(key, "must be \(T.self)")])
        }
    }

    func required<T: Decodable>(_ key: String, as _: T.Type = T.self) throws -> T {
        guard let v: T = try decode(key) else { throw LiftError.invalidInput([FieldError(key, "required")]) }
        return v
    }

    func flag(_ key: String) throws -> Bool { try decode(key) ?? false }

    /// All arguments as one body (jobs_submit).
    func whole<T: Decodable>(_: T.Type) throws -> T {
        do { return try Wire.decoder.decode(T.self, from: JSONEncoder().encode(values)) } catch let e as DecodingError {
            throw LiftError.invalidInput([Problem.field(e)])
        }
    }
}

/// What a tool returns: JSON (also as structured content), plain text, and links to job outputs.
enum ToolOutput {
    case json(any Encodable)
    case text(String)
    case job(JobView)
    /// A job, or a memory warning (spec §8: plain text first, then the warning as structured content; not an error).
    case admission(Admission<JobView>)
}

/// The MCP adapter's commands, one closure per tool. Each calls the same LiftCore command as its HTTP route.
enum Tools {
    typealias Progress = @Sendable (_ progress: Double, _ total: Double, _ message: String) async -> Void

    struct Context: Sendable {
        let lift: Lift
        let server: LiftServer
        /// Set when the request carried a progress token.
        let progress: Progress?
        var shared: Shared { Shared(lift: lift) }
    }

    static let handlers: [String: @Sendable (Args, Context) async throws -> ToolOutput] = [
        "jobs_submit": { a, c in .admission(try await c.shared.submit(a.whole(SubmitWire.self), inputs: Inputs(workdir: c.lift.config.workdir), source: .mcp)) },
        "jobs_list": { a, c in
            .json(JobListOut(jobs: try await c.lift.jobsList(JobFilter(states: try a.decode("state"), recipe: try a.decode("recipe"),
                                                                       modality: try a.decode("modality"), text: try a.decode("text")))))
        },
        "jobs_list_interrupted": { _, c in .json(JobListOut(jobs: try await c.lift.jobsListInterrupted())) },
        "jobs_resolve_interrupted": { a, c in
            .json(JobListOut(jobs: try await c.lift.jobsResolveInterrupted(ids: try a.decode("ids"), action: try a.required("action"))))
        },
        "jobs_get": { a, c in .job(try await c.lift.jobsGet(a.required("id"))) },
        "jobs_delete": { a, c in .json(DeletedOut(deleted: try gated(await c.lift.jobsDelete(a.required("id"), confirm: a.flag("confirm"))))) },
        "jobs_wait": { a, c in .job(try await wait(a, c)) },
        "jobs_cancel": { a, c in .job(try gated(await c.lift.jobsCancel(a.required("id"), confirm: a.flag("confirm")))) },
        "jobs_retry": { a, c in
            .admission(try await c.shared.retry(a.required("id"), settings: a.decode("settings"), acceptMemoryWarning: a.flag("accept_memory_warning")))
        },
        "jobs_move": { a, c in .job(try await c.shared.move(a.required("id"), before: a.decode("before"), after: a.decode("after"), index: a.decode("index"))) },
        "jobs_set_priority": { a, c in .job(try await c.lift.jobsSetPriority(a.required("id"), a.required("priority"))) },
        "jobs_force_start": { a, c in .job(try gated(await c.lift.jobsForceStart(a.required("id"), confirm: a.flag("confirm")))) },
        "queue_status": { _, c in .json(QueueOut(try await c.lift.queueStatus())) },
        "queue_resume": { _, c in .json(QueueOut(try await c.lift.queueResume())) },
        "models_list": { _, c in .json(ModelListOut(models: try await c.lift.modelsList())) },
        "models_get": { a, c in .json(ModelOut(try await c.lift.modelsGet(a.required("id")))) },
        "models_uninstall": { a, c in .json(UninstalledOut(model: try gated(await c.lift.modelsUninstall(a.required("id"), confirm: a.flag("confirm"))))) },
        "models_install": { a, c in
            .json(ModelOut(try gated(await c.lift.modelsInstall(a.required("id"), confirm: a.flag("confirm"), wait: a.flag("wait"),
                                                                downloadWeights: a.decode("download_weights") ?? true))))
        },
        "models_reinstall": { a, c in .json(ModelOut(try gated(await c.lift.modelsReinstall(a.required("id"), confirm: a.flag("confirm"), wait: a.flag("wait"))))) },
        "models_set_pin": { a, c in
            .json(ModelOut(try gated(await c.lift.modelsSetPin(a.required("id"), commit: a.required("commit"), confirm: a.flag("confirm"), wait: a.flag("wait")))))
        },
        "models_check_upstream": { a, c in .json(try await c.lift.modelsCheckUpstream(a.required("id"))) },
        "models_install_log": { a, c in .text(try await c.lift.modelsInstallLog(a.required("id"))) },
        "models_readme": { a, c in
            guard let readme = try await c.lift.modelsReadme(a.required("id")) else { throw LiftError.notFound("README for \(try a.required("id", as: String.self))") }
            return .json(readme)
        },
        "jobs_export": { a, c in .job(try await c.lift.jobsExport(a.required("id"), formats: a.decode("formats"), dir: a.decode("dir"))) },
        "models_download_weights": { a, c in
            .json(ModelOut(try gated(await c.lift.modelsDownloadWeights(a.required("id"), confirm: a.flag("confirm"), wait: a.flag("wait")))))
        },
        "models_verify_weights": { a, c in .json(try await c.lift.modelsVerifyWeights(a.required("id"))) },
        "models_cancel_install": { a, c in .json(ModelOut(try await c.lift.modelsCancelInstall(a.required("id")))) },
        "downloads_list": { _, c in .json(DownloadListOut(downloads: await c.lift.downloadsList())) },
        "downloads_pause": { a, c in .json(try await c.lift.downloadsPause(a.required("id"))) },
        "downloads_resume": { a, c in .json(try await c.lift.downloadsResume(a.required("id"))) },
        "downloads_cancel": { a, c in .json(try gated(await c.lift.downloadsCancel(a.required("id"), confirm: a.flag("confirm")))) },
        "downloads_retry": { a, c in .json(try await c.lift.downloadsRetry(a.required("id"))) },
        "downloads_reorder": { a, c in .json(DownloadListOut(downloads: try await c.lift.downloadsReorder(a.required("id"), position: a.required("position")))) },
        "recipes_list": { _, c in .json(await c.shared.recipes()) },
        "workers_list": { _, c in .json(WorkerListOut(workers: await c.lift.workersList())) },
        "workers_load": { a, c in .json(try await c.lift.workersLoad(a.required("recipe"))) },
        "workers_unload": { a, c in .json(WorkerListOut(workers: try gated(await c.lift.workersUnload(a.required("id"), confirm: a.flag("confirm"))))) },
        "resources_get": { _, c in .json(try await c.lift.resourcesGet()) },
        "resources_set": { a, c in
            _ = try await c.lift.resourcesSet(maxSlots: a.decode("max_slots"), memoryBudgetGB: a.decode("memory_budget_gb"),
                                              idleUnloadMinutes: a.decode("idle_unload_minutes"))
            return .json(await c.server.settings())
        },
        "settings_get": { _, c in .json(await c.server.settings()) },
        "settings_set": { a, c in .json(try await c.server.setSetting(a.required("key"), a.required("value"))) },
        "server_status": { _, c in .json(await c.server.status()) },
        "server_set_lan": { a, c in .json(try gated(await c.server.setLAN(a.required("enabled"), confirm: a.flag("confirm")))) },
        "server_rotate_token": { a, c in .json(try gated(await c.server.rotateToken(confirm: a.flag("confirm")))) },
        "secrets_set_hf_token": { a, c in .json(try await c.server.secretsSetHFToken(a.decode("token"))) },
        "system_prereqs": { a, c in .json(await c.lift.systemPrereqs(checkMetal: try a.flag("metal"))) },
        "system_install_prereqs": { a, c in .json(try gated(await c.lift.systemInstallPrereqs(metal: a.flag("metal"), confirm: a.flag("confirm")))) },
    ]

    /// `jobs_wait` with progress notifications: progress = finished steps + the current step's fraction, out of the step count.
    static func wait(_ a: Args, _ c: Context) async throws -> JobView {
        guard let progress = c.progress else { return try await c.shared.wait(a.required("id"), seconds: a.decode("timeout_seconds")) }
        let (updates, continuation) = AsyncStream<JobView>.makeStream()
        let sender = Task {
            var last: (Double, String)?
            for await v in updates {
                let done = Double(v.steps.filter { $0.state == .succeeded }.count)
                let current = v.job.state.isTerminal ? 0 : v.steps.first { $0.idx == v.job.currentStep }?.fraction ?? 0
                let value = max(last?.0 ?? 0, done + current)
                let stage = v.steps.first { $0.idx == v.job.currentStep }?.stage
                let message = [v.job.state.rawValue, stage].compactMap { $0 }.joined(separator: " · ")
                guard last.map({ $0.0 != value || $0.1 != message }) ?? true else { continue }
                last = (value, message)
                await progress(value, Double(v.steps.count), message)
            }
        }
        defer { continuation.finish() }
        let view = try await c.shared.wait(a.required("id"), seconds: a.decode("timeout_seconds")) { continuation.yield($0) }
        continuation.finish()
        await sender.value
        return view
    }

    static func call(_ params: CallTool.Parameters, _ context: Context) async -> CallTool.Result {
        guard let handler = handlers[params.name] else {
            return result(Problem(error: "not_found", message: "unknown tool \(params.name)", status: 404), isError: true)
        }
        do {
            switch try await handler(Args(values: params.arguments ?? [:]), context) {
            case .json(let value): return result(value)
            case .text(let text): return CallTool.Result(content: [.text(text: text, annotations: nil, _meta: nil)])
            case .admission(.memoryWarning(let warning)):
                let out = MemoryWarningOut(memoryWarning: warning)
                var r = result(out)
                r = CallTool.Result(content: [.text(text: "\(warning.message) \(out.hint)", annotations: nil, _meta: nil)] + r.content,
                                    structuredContent: r.structuredContent)
                return r
            case .admission(.accepted(let view)), .job(let view):
                let out = JobOut(view)
                var r = result(out)
                let links = out.outputs.map { Tool.Content.resourceLink(uri: $0.uri, name: URL(filePath: $0.path).lastPathComponent, mimeType: Resources.mimeType($0.path)) }
                r = CallTool.Result(content: r.content + links, structuredContent: r.structuredContent)
                return r
            }
        } catch {
            return result(Problem.from(error), isError: true)
        }
    }

    static func result(_ value: any Encodable, isError: Bool? = nil) -> CallTool.Result {
        let data = (try? Wire.data(value)) ?? Data("{}".utf8)
        return CallTool.Result(content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                               structuredContent: try? JSONDecoder().decode(Value.self, from: data), isError: isError)
    }
}
