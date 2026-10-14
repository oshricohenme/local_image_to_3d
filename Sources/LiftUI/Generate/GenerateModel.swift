import Foundation
import LiftCore
import Observation

/// A task's shape, used to group the same kind of task across recipes into one chip.
public struct TaskKind: Hashable, Sendable {
    public var inputs: [IOType]
    public var output: IOType

    public var label: String {
        inputs.map { Format.io($0) }.joined(separator: " + ") + " → " + Format.io(output, asOutput: true)
    }
}

/// One recipe task, addressed the way a step names it.
public struct TaskRef: Hashable, Sendable {
    public var recipe: String
    public var task: String
}

public struct TaskChip: Identifiable, Sendable {
    public var kind: TaskKind
    /// Recipes offering it, in catalog order.
    public var models: [ModelView]
    public var id: TaskKind { kind }
}

/// Generate screen state: modality → task chip → recipe → settings → inputs, plus an optional
/// follow-up step, priority and export options. It builds requests; the user decides everything.
@MainActor @Observable
public final class GenerateModel {
    public nonisolated static let modalities = [("3d", "3D"), ("image", "Image"), ("music", "Music"), ("video", "Video"), ("audio", "Audio")]

    public var models: [ModelView] = [] {
        didSet { reconcile() }
    }
    public var modality = "3d" {
        didSet { if modality != oldValue { kind = nil; reconcile() } }
    }
    public var kind: TaskKind? {
        didSet { if kind != oldValue { recipe = nil; reconcile() } }
    }
    public var recipe: String? {
        didSet { if recipe != oldValue { values = defaults(for: current) } }
    }
    public var values: [String: SettingValue] = [:]
    /// Files for the task's first input, one job per file.
    public var files: [URL] = []
    /// Text for a first input of type `text`, and fixed values for inputs after the first.
    public var text = ""
    public var otherInputs: [String: String] = [:]
    public var then: TaskRef? {
        didSet { if then != oldValue { thenValues = defaults(for: then) } }
    }
    public var thenValues: [String: SettingValue] = [:]
    public var priority: Priority = .normal
    /// Export (spec §7, §9): where the result goes and in which formats. Starts from the export settings
    /// and follows them until the user changes it here. No formats means the job only keeps its own copy.
    public var exportFormats: Set<ExportFormat> = [.glb] { didSet { exportEdited = exportEdited || !adopting } }
    public var exportOriginal = true { didSet { exportEdited = true } }
    /// nil: the `export_dir` setting.
    public var exportDir: String? { didSet { exportEdited = exportEdited || !adopting } }
    public var cleanupAfterExport = false { didSet { exportEdited = exportEdited || !adopting } }
    var exportEdited = false
    private var adopting = false
    public var errors: [FieldError] = []

    public init() {}

    // MARK: derived

    public func taskCount(_ modality: String) -> Int { chips(modality).count }

    public func chips(_ modality: String) -> [TaskChip] {
        var order: [TaskKind] = []
        var byKind: [TaskKind: [ModelView]] = [:]
        for m in models {
            for t in m.recipe.tasks where t.modality == modality {
                let k = TaskKind(inputs: t.inputs.map(\.type), output: t.output)
                if byKind[k] == nil { order.append(k) }
                if byKind[k]?.contains(where: { $0.id == m.id }) != true { byKind[k, default: []].append(m) }
            }
        }
        return order.map { TaskChip(kind: $0, models: byKind[$0] ?? []) }
    }

    /// The selected recipe task.
    public var current: TaskRef? {
        guard let kind, let recipe, let m = models.first(where: { $0.id == recipe }),
              let t = m.recipe.tasks.first(where: { TaskKind(inputs: $0.inputs.map(\.type), output: $0.output) == kind && $0.modality == modality })
        else { return nil }
        return TaskRef(recipe: m.id, task: t.id)
    }

    public func task(_ ref: TaskRef?) -> RecipeTask? {
        guard let ref else { return nil }
        return models.first { $0.id == ref.recipe }?.recipe.task(ref.task)
    }

    /// Tasks (any recipe, any modality) whose first input accepts the current task's output.
    public var followUps: [TaskRef] {
        guard let output = task(current)?.output else { return [] }
        return models.filter { !$0.isUnsupported }.flatMap { m in
            m.recipe.tasks.filter { $0.inputs.first?.type.accepts(output) == true }.map { TaskRef(recipe: m.id, task: $0.id) }
        }
    }

    /// One request per file (or one for a text first input).
    public var requests: [SubmitRequest] {
        guard let ref = current, let task = task(ref), let first = task.inputs.first else { return [] }
        let firsts: [String] = first.type == .text ? (text.isEmpty ? [] : [text]) : files.map(\.path)
        return firsts.map { value in
            var inputs = otherInputs.filter { k, _ in task.inputs.dropFirst().contains { $0.name == k } }
            inputs[first.name] = value
            var steps = [StepRequest(recipe: ref.recipe, task: ref.task, inputs: inputs, settings: values)]
            if let then { steps.append(StepRequest(recipe: then.recipe, task: then.task, settings: thenValues)) }
            return SubmitRequest(steps: steps, priority: priority, source: .ui, export: export)
        }
    }

    /// What each request asks for. Untouched, it defers to the export settings entirely (so no export folder
    /// yet simply means no export); once changed here, these formats, this folder (or the setting's) and cleanup.
    public var export: ExportSpec {
        guard exportEdited else { return ExportSpec() }
        let formats = availableExportFormats == [.original] ? (exportOriginal ? [.original] : []) : availableExportFormats.filter(exportFormats.contains)
        return ExportSpec(dir: exportDir, formats: formats, cleanupAfterExport: cleanupAfterExport)
    }

    public var availableExportFormats: [ExportFormat] {
        let output = task(then ?? current)?.output
        return output == .mesh || output == .riggedMesh ? ExportFormat.allCases : [.original]
    }

    /// The export settings, until the user changes the export options in this form.
    public func adoptExportDefaults(_ settings: Settings) {
        guard !exportEdited else { return }
        adopting = true
        defer { adopting = false }
        exportFormats = Set(settings.exportFormats)
        exportDir = settings.exportDir
        cleanupAfterExport = settings.cleanupAfterExport
    }

    public func errors(forSetting key: String, step: Int) -> [String] {
        errors.filter { $0.field == "steps[\(step)].settings.\(key)" }.map(\.message)
    }

    // MARK: changes

    /// The first input's type, which decides what the drop zone takes.
    public var firstInput: TaskInput? { task(current)?.inputs.first }

    /// Adds dropped or chosen files that fit the first input; returns how many. For `image_set`, each folder is
    /// a set, and the photos added together make one more: a folder of links to them, named "N photos".
    @discardableResult
    public func add(_ urls: [URL]) -> Int {
        guard let type = firstInput?.type else { return 0 }
        let before = files.count
        var photos: [URL] = []
        for url in urls where !files.contains(url) {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let fits = IOType.image.fileExtensions.contains(url.pathExtension.lowercased())
            if type == .imageSet {
                if isDir { files.append(url) } else if fits, !photos.contains(url) { photos.append(url) }
            } else if !isDir && type.fileExtensions.contains(url.pathExtension.lowercased()) {
                files.append(url)
            }
        }
        if !photos.isEmpty, let set = Self.photoSet(photos) { files.append(set) }
        return files.count - before
    }

    /// A temporary folder of links to `photos` (the job copies the photos themselves). Same-named photos keep the first.
    static func photoSet(_ photos: [URL]) -> URL? {
        let fm = FileManager.default
        let set = fm.temporaryDirectory.appending(path: "Lift photo sets/\(UUID().uuidString)/\(photos.count) photo\(photos.count == 1 ? "" : "s")")
        guard (try? fm.createDirectory(at: set, withIntermediateDirectories: true)) != nil else { return nil }
        for p in photos { try? fm.createSymbolicLink(at: set.appending(path: p.lastPathComponent), withDestinationURL: p) }
        return set
    }

    /// Prefills the form to use `path` (an output) as the input of `ref` ("Use as input for…").
    public func use(_ path: String, for ref: TaskRef) {
        guard let m = models.first(where: { $0.id == ref.recipe }), let t = m.recipe.task(ref.task) else { return }
        modality = t.modality
        kind = TaskKind(inputs: t.inputs.map(\.type), output: t.output)
        recipe = ref.recipe
        files = [URL(filePath: path)]
    }

    func defaults(for ref: TaskRef?) -> [String: SettingValue] {
        var out: [String: SettingValue] = [:]
        for def in task(ref)?.settings ?? [] { out[def.key] = def.default }
        return out
    }

    /// Keeps the selection valid after the model list or modality changes. The first chip is shown
    /// (navigation only); a recipe is never picked for the user (spec principle 2).
    func reconcile() {
        let chips = chips(modality)
        if kind == nil || !chips.contains(where: { $0.kind == kind }) { kind = chips.first?.kind }
        let offered = chips.first { $0.kind == kind }?.models ?? []
        if let recipe, !offered.contains(where: { $0.id == recipe && !$0.isUnsupported }) { self.recipe = nil }
        if let then, !followUps.contains(then) { self.then = nil }
    }
}

public extension ModelView {
    var isUnsupported: Bool {
        if case .unsupported = status { true } else { false }
    }
    var isInstalled: Bool {
        switch status {
        case .installed, .updateAvailable: true
        default: false
        }
    }
}
