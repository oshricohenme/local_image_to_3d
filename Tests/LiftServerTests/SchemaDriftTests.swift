import Foundation
import Testing
@testable import LiftCore
@testable import LiftServer

/// Every response goes through openapi.yaml's generated types, which drop any field the yaml doesn't list.
/// So every field the server can send must be in the yaml. For each returned type this checks two things:
/// 1. A fully populated sample, encoded as the server encodes it, has only keys the schema lists, and has
///    every key the schema requires.
/// 2. Every stored Swift property (via Mirror, so even a new optional that is nil) is in the schema.
/// A new LiftCore or Plan 4 field fails here until openapi.yaml lists it.
@Suite struct SchemaDriftTests {
    static var doc: [String: Any] { try! JSONSerialization.jsonObject(with: OpenAPIDocument.json) as! [String: Any] }

    static func resolve(_ node: Any?) -> [String: Any] {
        guard var schema = node as? [String: Any] else { return [:] }
        while let ref = schema["$ref"] as? String {
            schema = ref.split(separator: "/").dropFirst().reduce(doc as Any?) { ($0 as? [String: Any])?[String($1)] } as? [String: Any] ?? [:]
        }
        return schema
    }

    static func schema(_ name: String) -> [String: Any] { resolve(["$ref": "#/components/schemas/\(name)"]) }

    /// Encoded keys against the schema, recursing wherever the schema lists properties (free-form objects stop it).
    static func keys(_ json: Any, _ schema: [String: Any], _ path: String) -> [String] {
        if let items = schema["items"], let array = json as? [Any] {
            return array.prefix(1).flatMap { keys($0, resolve(items), path + "[0]") }
        }
        guard let props = schema["properties"] as? [String: Any], let object = json as? [String: Any] else { return [] }
        var out: [String] = []
        for (k, v) in object.sorted(by: { $0.key < $1.key }) {
            guard let p = props[k] else { out.append("\(path).\(k) is sent but not in openapi.yaml"); continue }
            out += keys(v, resolve(p), path + "." + k)
        }
        for k in (schema["required"] as? [String] ?? []).sorted() where object[k] == nil {
            out.append("\(path).\(k) is required by openapi.yaml but not sent")
        }
        return out
    }

    /// Stored Swift properties against the schema.
    static func fields(_ value: Any, _ schema: [String: Any], _ path: String) -> [String] {
        let mirror = Mirror(reflecting: value)
        switch mirror.displayStyle {
        case .optional:
            return mirror.children.first.map { fields($0.value, schema, path) } ?? []
        case .collection:
            guard let items = schema["items"] else { return [] }
            return mirror.children.first.map { fields($0.value, resolve(items), path + "[0]") } ?? []
        case .struct, .class:
            guard let props = schema["properties"] as? [String: Any] else { return [] }
            return mirror.children.flatMap { child -> [String] in
                guard let label = child.label else { return [] }
                let key = snake(label)
                guard let p = props[key] else { return ["\(path).\(key) is a Swift property but not in openapi.yaml"] }
                return fields(child.value, resolve(p), path + "." + key)
            }
        default:
            return []  // enums (ModelStatus, WaitReason) and dictionaries: checked through their encoding
        }
    }

    /// A property name as the server's encoder writes it (Wire.encoder, convertToSnakeCase).
    static func snake(_ name: String) -> String {
        struct Probe: Encodable {
            struct Key: CodingKey {
                var stringValue: String
                init(stringValue: String) { self.stringValue = stringValue }
                var intValue: Int? { nil }
                init?(intValue: Int) { nil }
            }
            let name: String
            func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: Key.self)
                try c.encode(0, forKey: Key(stringValue: name))
            }
        }
        let object = try! JSONSerialization.jsonObject(with: Wire.data(Probe(name: name))) as! [String: Any]
        return object.keys.first!
    }

    static func check(_ value: some Encodable, _ name: String, mirrors: [Any]? = nil) throws -> [String] {
        let json = try JSONSerialization.jsonObject(with: Wire.data(value))
        let s = schema(name)
        return keys(json, s, name) + (mirrors ?? [value]).flatMap { fields($0, s, name) }
    }

    /// Records one issue per drifted field, naming it.
    static func verify(_ value: some Encodable, _ name: String, mirrors: [Any]? = nil, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let problems = try check(value, name, mirrors: mirrors)
        #expect(problems.isEmpty, Comment(rawValue: problems.joined(separator: "\n")), sourceLocation: sourceLocation)
    }

    // MARK: fully populated samples

    static let at = Date(timeIntervalSince1970: 1_800_000_000)

    static var job: JobRecord {
        JobRecord(id: "j1", title: "t", priority: .high, position: 1, source: .mcp, state: .waiting, waitReason: .memory(needed: 2, free: 1),
                  forceStart: true, memoryAccepted: true, currentStep: 0, error: "e", createdAt: at, updatedAt: at, finishedAt: at)
    }

    static var step: StepRecord {
        StepRecord(jobId: "j1", idx: 0, recipe: "test-cube", task: "image_to_3d", inputs: ["image": "/i.png"], settings: ["size": .float(2)],
                   state: .succeeded, waitReason: .noFreeSlot, stage: "Generating", fraction: 1, outputs: ["/w/jobs/j1/steps/0/cube.glb"],
                   error: "e", workerId: "w1", startedAt: at, finishedAt: at)
    }

    static var jobView: JobView {
        var j = job
        j.state = .succeeded
        return JobView(job: j, steps: [step])
    }

    static var weights: WeightsReport {
        WeightsReport(state: .corrupt, problems: [WeightProblem(repo: "o/r", path: "m.bin", issue: .wrongHash, detail: "d")], checkedAt: at,
                      hashedFiles: 1, metadataFrom: at, note: "n", upstreamMoved: ["o/r: main moved"])
    }

    static func model() throws -> ModelView {
        guard case .ok(let recipe) = RecipeLoad.read(directory: Fixtures.devRecipes.appending(path: "test-cube")) else {
            throw LiftError.invalidState("test-cube recipe didn't load")
        }
        return ModelView(id: "test-cube", name: "Test Cube", source: "bundled", status: .installed(commit: "c"), recipe: recipe, pin: "p",
                         diskBytes: 1, weights: weights)
    }

    static var worker: WorkerView {
        WorkerView(id: "w1", recipe: "test-cube", pid: 1, ready: true, job: "j1", footprintBytes: 1, reservedBytes: 1)
    }

    static var memoryWarning: MemoryWarning {
        MemoryWarning(message: "m", neededGB: 18, physicalGB: 16, budgetGB: 12, step: 0)
    }

    static func server() async throws -> ServerStatus {
        await LiftServer(lift: try await Fixtures.lift()).status()
    }

    // MARK: the checks

    @Test func jobsAndQueue() throws {
        try Self.verify(JobOut(Self.jobView), "JobView", mirrors: [Self.jobView])
        try Self.verify(JobListOut(jobs: [JobOut(Self.jobView)]), "JobList")
        let queue = QueueStatus(paused: true, maxSlots: 1, running: 1, jobs: [Self.jobView])
        try Self.verify(QueueOut(queue), "QueueStatus", mirrors: [queue])
        try Self.verify(MemoryWarningOut(memoryWarning: Self.memoryWarning), "MemoryWarningResult")
        try Self.verify(DeletedOut(deleted: true), "Deleted")
    }

    @Test func modelsAndRecipes() throws {
        let model = try Self.model()
        try Self.verify(model, "ModelView")
        try Self.verify(ModelListOut(models: [model]), "ModelList")
        try Self.verify(UninstalledOut(model: model), "Uninstalled")
        try Self.verify(Self.weights, "WeightsReport")
        try Self.verify(UpstreamStatus(pin: "p", head: "h", commitsAhead: 1), "UpstreamStatus")
        let listing = RecipeListing(id: "test-cube", name: "Test Cube", source: "bundled", state: .needsNewerLift, detail: "d")
        try Self.verify(RecipesOut(recipes: [listing]), "RecipeList")
    }

    @Test func workersResourcesAndSystem() throws {
        try Self.verify(Self.worker, "WorkerView")
        try Self.verify(WorkerListOut(workers: [Self.worker]), "WorkerList")
        let resources = ResourcesView(maxSlots: 1, budgetBytes: 1, reservedBytes: 1, systemFreeBytes: 1, workers: [Self.worker],
                                      estimates: [EstimateView(recipe: "r", task: "t", keyValues: "{}", loadBytes: 1, jobBytes: 1)])
        try Self.verify(resources, "Resources")
        let prereqs = Prereqs(tools: ToolPaths(brew: "/b", git: "/g", uv: "/u", rosettaBrew: "/usr/local/bin/brew"), metalToolchain: true)
        try Self.verify(prereqs, "Prereqs")
    }

    @Test func settingsServerAndErrors() async throws {
        var core = Settings()
        core.pinOverrides = ["test-cube": "c"]
        let settings = SettingsOut(core: core, server: ServerSettings())
        try Self.verify(settings, "Settings", mirrors: [core, ServerSettings()])
        let status = try await Self.server()
        try Self.verify(status, "ServerStatus")
        try Self.verify(ServerChange(server: status, token: "t"), "ServerChange")
        try Self.verify(SecretsStatus(hfTokenSet: true), "SecretsStatus")
        var problem = Problem.from(LiftError.commandFailed(command: "c", exitCode: 1, tail: ["t"]))
        problem.fields = [FieldError("f", "m")]
        problem.impact = "i"
        try Self.verify(problem, "Problem", mirrors: [])  // `status` is the HTTP status, not a field
    }
}
