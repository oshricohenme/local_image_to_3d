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

/// A job in a list (queue_status, jobs_list): where it stands and what it made, nothing more.
/// Who made the models (credits) stays in the app and in each export's credits file.
struct JobSummary: Encodable, Sendable {
    var id: String
    var title: String
    var state: JobState
    var priority: Priority
    var position: Double
    var waitReason: WaitReason?
    var error: String?
    /// 0-based, of `stepCount`.
    var currentStep: Int
    var stepCount: Int
    /// The current step's.
    var recipe: String?
    var stage: String?
    var fraction: Double?
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?
    var outputs: [OutputFile]
    var exports: [ExportResult]
    var exportPending: Bool

    init(_ v: JobView) {
        let step = v.steps.first { $0.idx == v.job.currentStep }
        id = v.job.id
        title = v.job.title
        state = v.job.state
        priority = v.job.priority
        position = v.job.position
        waitReason = v.job.waitReason
        error = v.job.error
        currentStep = v.job.currentStep
        stepCount = v.steps.count
        recipe = step?.recipe
        stage = step?.stage
        fraction = step?.fraction
        createdAt = v.job.createdAt
        startedAt = v.steps.first?.startedAt
        finishedAt = v.job.finishedAt
        outputs = v.outputs.map { OutputFile(job: v.job.id, path: $0) }
        exports = v.job.exports
        exportPending = v.job.exportPending
    }
}

/// One step as jobs_get shows it: what ran, with which inputs and settings, and how it went.
struct StepOut: Encodable, Sendable {
    var recipe: String
    var task: String
    var state: JobState
    var inputs: [String: String]
    var settings: [String: SettingValue]
    var stage: String?
    var fraction: Double?
    var error: String?
    var startedAt: Date?
    var finishedAt: Date?

    init(_ s: StepRecord) {
        (recipe, task, state, inputs, settings) = (s.recipe, s.task, s.state, s.inputs, s.settings)
        (stage, fraction, error, startedAt, finishedAt) = (s.stage, s.fraction, s.error, s.startedAt, s.finishedAt)
    }
}

/// One job (jobs_get, submit, wait, cancel …): the summary's fields, plus its steps and export folder.
struct JobOut: Encodable, Sendable {
    var summary: JobSummary
    var steps: [StepOut]
    var export: ExportSpec?
    var cleanedUp: Bool
    var outputs: [OutputFile] { summary.outputs }

    init(_ v: JobView) {
        summary = JobSummary(v)
        steps = v.steps.map(StepOut.init)
        export = v.job.export
        cleanedUp = v.job.cleanedUp
    }

    enum CodingKeys: String, CodingKey { case steps, export, cleanedUp }

    func encode(to encoder: any Encoder) throws {
        try summary.encode(to: encoder)  // same object: JSONEncoder merges keyed containers
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(steps, forKey: .steps)
        try c.encodeIfPresent(export, forKey: .export)
        if cleanedUp { try c.encode(true, forKey: .cleanedUp) }
    }
}

struct JobListOut: Encodable {
    var jobs: [JobSummary]
    init(jobs: [JobView]) { self.jobs = jobs.map(JobSummary.init) }
}

struct QueueOut: Encodable {
    var paused: Bool
    var maxSlots: Int
    var running: Int
    var jobs: [JobSummary]

    init(_ q: QueueStatus) {
        paused = q.paused
        maxSlots = q.maxSlots
        running = q.running
        jobs = q.jobs.map(JobSummary.init)
    }
}

/// A model in models_list: what it is, whether it's ready, and what it can do. models_get has the details.
struct ModelSummary: Encodable, Sendable {
    var id: String
    var name: String
    var description: String?
    var status: ModelStatus
    /// Task ids (submit's `task`).
    var tasks: [String]
    var progress: InstallProgress?
    var download: DownloadBrief?

    init(_ m: ModelView) {
        (id, name, description, status) = (m.id, m.name, m.recipe.description, m.status)
        tasks = m.recipe.tasks.map(\.id)
        progress = m.progress
        download = m.download.map(DownloadBrief.init)
    }
}

/// A weights download's state, and why it stopped (with the page to accept terms on, for gated weights).
struct DownloadBrief: Encodable, Sendable {
    var state: String
    var reason: String?
    var link: URL?
    init(_ d: Download) { (state, reason, link) = (d.state.rawValue, d.reason, d.link) }
}

/// One model (models_get, install, reinstall …): the summary's fields, plus each task's inputs and settings
/// (what submit needs), its memory needs, pin, disk use and weights check. No credits, install steps or file lists.
struct ModelOut: Encodable, Sendable {
    struct TaskOut: Encodable, Sendable {
        var id: String
        var label: String
        var modality: String
        var inputs: [TaskInput]
        var output: IOType
        var settings: [SettingDef]
        init(_ t: RecipeTask) { (id, label, modality, inputs, output, settings) = (t.id, t.label, t.modality, t.inputs, t.output, t.settings) }
    }

    var id: String
    var name: String
    var description: String?
    var status: ModelStatus
    var tasks: [TaskOut]
    var memoryGB: Double
    var memoryOverrides: [Recipe.MemoryOverride]
    var pin: String?
    var diskBytes: Int?
    var weights: WeightsReport?
    var progress: InstallProgress?
    var download: Download?

    init(_ m: ModelView) {
        (id, name, description, status) = (m.id, m.name, m.recipe.description, m.status)
        tasks = m.recipe.tasks.map(TaskOut.init)
        memoryGB = m.recipe.resources.memoryGB
        memoryOverrides = m.recipe.resources.memoryOverrides
        (pin, diskBytes, weights, progress, download) = (m.pin, m.diskBytes, m.weights, m.progress, m.download)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, status, tasks, memoryGB = "memory_gb", memoryOverrides, pin, diskBytes, weights, progress, download
    }
}

struct ModelListOut: Encodable {
    var models: [ModelSummary]
    init(models: [ModelView]) { self.models = models.map(ModelSummary.init) }
}
struct DownloadListOut: Encodable { var downloads: [Download] }
struct WorkerListOut: Encodable { var workers: [WorkerView] }
struct UninstalledOut: Encodable {
    var model: ModelOut?
    init(model: ModelView?) { self.model = model.map(ModelOut.init) }
}
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
