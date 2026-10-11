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
    public nonisolated static let modalities = [("3d", "3D"), ("image", "Image"), ("video", "Video"), ("audio", "Audio")]

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
            return SubmitRequest(steps: steps, priority: priority, source: .ui)
        }
    }

    public func errors(forSetting key: String, step: Int) -> [String] {
        errors.filter { $0.field == "steps[\(step)].settings.\(key)" }.map(\.message)
    }

    // MARK: changes

    /// The first input's type, which decides what the drop zone takes.
    public var firstInput: TaskInput? { task(current)?.inputs.first }

    /// Adds dropped or chosen files that fit the first input (folders for `image_set`); returns how many.
    @discardableResult
    public func add(_ urls: [URL]) -> Int {
        guard let type = firstInput?.type else { return 0 }
        let before = files.count
        for url in urls where !files.contains(url) {
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if type == .imageSet ? isDir : !isDir && type.fileExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
        }
        return files.count - before
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
