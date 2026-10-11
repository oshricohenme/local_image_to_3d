import LiftCore
import SwiftUI
import UniformTypeIdentifiers

/// Generate (mockup Main.dc.html): modality tabs, task chips, inputs, the recipe's options form,
/// an optional follow-up step ("Then"), priority, and Add to Queue.
struct GenerateView: View {
    let app: AppModel
    @Bindable var model: GenerateModel
    @State private var choosing = false

    init(app: AppModel) {
        self.app = app
        model = app.generate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Modality", selection: $model.modality) {
                ForEach(GenerateModel.modalities, id: \.0) { id, label in
                    Text("\(label)  \(model.taskCount(id))").tag(id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            let chips = model.chips(model.modality)
            if chips.isEmpty {
                ContentUnavailableView {
                    Label("No \(GenerateModel.modalities.first { $0.0 == model.modality }?.1 ?? "") projects yet", systemImage: "square.dashed")
                } description: {
                    Text("Once a recipe that offers a task of this kind is added, it appears here with its options.")
                } actions: {
                    Button("Browse or add recipes") { app.section = .models }
                }
            } else {
                chipRow(chips)
                HStack(alignment: .top, spacing: 16) {
                    inputs.frame(minWidth: 320, maxWidth: .infinity)
                    options.frame(width: 380)
                }
            }
        }
        .padding()
        .navigationTitle("Generate")
    }

    func chipRow(_ chips: [TaskChip]) -> some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(chips) { chip in
                    Toggle(isOn: Binding(get: { model.kind == chip.kind }, set: { if $0 { model.kind = chip.kind } })) {
                        VStack(alignment: .leading) {
                            Text(chip.kind.label).bold()
                            Text(chip.models.map(\.name).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.button)
                }
            }
        }
    }

    // MARK: inputs

    @ViewBuilder var inputs: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let first = model.firstInput {
                if first.type == .text {
                    Text(first.name.capitalized).font(.headline)
                    TextEditor(text: $model.text).frame(minHeight: 120).border(.separator)
                } else {
                    dropZone(first)
                    if !model.files.isEmpty {
                        HStack {
                            Text("Ready to queue · \(model.files.count)").font(.headline)
                            Spacer()
                            Button("Clear") { model.files = [] }
                        }
                        List(model.files, id: \.self) { url in
                            Label(url.lastPathComponent, systemImage: first.type == .imageSet ? "folder" : "doc")
                        }
                        .frame(minHeight: 120)
                    }
                }
                otherInputs
            } else {
                Text("Choose a project on the right.").foregroundStyle(.secondary)
            }
            Spacer()
            submitBar
        }
    }

    func dropZone(_ input: TaskInput) -> some View {
        let what = input.type == .imageSet ? "folders (one multi-view set each)" : input.type.fileExtensions.joined(separator: ", ")
        return VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down").font(.largeTitle)
            Text("Drop \(Format.io(input.type).lowercased()) files here").font(.headline)
            Text("Accepts \(what) · one job per file").font(.caption).foregroundStyle(.secondary)
            Button("Choose Files…") { choosing = true }
        }
        .frame(maxWidth: .infinity, minHeight: 160)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6])).foregroundStyle(.secondary))
        .dropDestination(for: URL.self) { urls, _ in model.add(urls) > 0 }
        .fileImporter(isPresented: $choosing, allowedContentTypes: contentTypes(input.type), allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.add(urls) }
        }
    }

    func contentTypes(_ type: IOType) -> [UTType] {
        type == .imageSet ? [.folder] : type.fileExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    /// Inputs after the first: one fixed value each (a path, or text).
    @ViewBuilder var otherInputs: some View {
        if let task = model.task(model.current) {
            ForEach(task.inputs.dropFirst(), id: \.name) { input in
                TextField(input.name, text: Binding(get: { model.otherInputs[input.name] ?? "" }, set: { model.otherInputs[input.name] = $0 }),
                          prompt: Text(input.type == .text ? "Text" : "Path to a \(Format.io(input.type).lowercased()) file"))
            }
        }
    }

    var submitBar: some View {
        let count = model.requests.count
        let chain = ([model.current] + [model.then]).compactMap { ref in ref.flatMap { r in model.models.first { $0.id == r.recipe }?.name } }
        return HStack {
            VStack(alignment: .leading) {
                Text("\(count) job\(count == 1 ? "" : "s") → \(chain.joined(separator: " → "))").bold()
                if let current = model.current, let m = model.models.first(where: { $0.id == current.recipe }), !m.isInstalled {
                    Text("\(m.name) is \(Format.status(m.status).lowercased()). Jobs wait in the queue until it's installed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(model.errors.filter { !$0.field.contains(".settings.") }, id: \.field) { e in
                    Text("\(e.field): \(e.message)").font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            Button("Add \(count) to Queue") { app.submitGenerate() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(count == 0)
        }
    }

    // MARK: options

    var options: some View {
        Form {
            projectSection
            optionsSection
            thenSection
            Section("Queue") {
                Picker("Priority", selection: $model.priority) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }

    var offered: [ModelView] { model.chips(model.modality).first { $0.kind == model.kind }?.models ?? [] }

    var projectSection: some View {
        Section("1 · Generate with") {
            Picker("Project", selection: $model.recipe) {
                Text("Choose…").tag(String?.none)
                ForEach(offered, id: \.id) { m in
                    Text(m.name + " — " + (m.isUnsupported ? "unsupported" : Format.status(m.status).lowercased()))
                        .tag(Optional(m.id))
                        .selectionDisabled(m.isUnsupported)
                }
            }
            if let m = offered.first(where: { $0.id == model.recipe }) {
                if !m.isInstalled && !m.isUnsupported {
                    Button("Install \(m.name)…") {
                        app.gated { confirm in try await app.engine.modelsInstall(m.id, confirm: confirm) }
                    }
                }
                HStack {
                    Text(recipeLine(m)).font(.caption).foregroundStyle(.secondary)
                    Button("About") { app.section = .models }.buttonStyle(.link).font(.caption)
                }
            }
            ForEach(offered.filter(\.isUnsupported), id: \.id) { m in
                if case .unsupported(let reason) = m.status {
                    Text(m.name + ": " + reason).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Credit first (spec §4a): who made it and its license; the repo and pin only in developer mode.
    func recipeLine(_ m: ModelView) -> String {
        var line = "by " + (m.recipe.publisher ?? "its authors") + " · " + (m.recipe.license ?? "license not stated")
        if app.developer, let repo = m.recipe.repo { line += " · " + repo + (m.pin.map { " @ " + String($0.prefix(7)) } ?? "") }
        return line
    }

    @ViewBuilder var optionsSection: some View {
        if let task = model.task(model.current), !task.settings.isEmpty {
            Section("Options") {
                SettingsForm(defs: task.settings, values: $model.values) { model.errors(forSetting: $0, step: 0) }
            }
        }
    }

    @ViewBuilder var thenSection: some View {
        if !model.followUps.isEmpty {
            Section("2 · Then") {
                Picker("Then", selection: $model.then) {
                    Text("Nothing").tag(TaskRef?.none)
                    ForEach(model.followUps, id: \.self) { ref in
                        Text(followUpLabel(ref)).tag(Optional(ref))
                    }
                }
                if let task = model.task(model.then), !task.settings.isEmpty {
                    SettingsForm(defs: task.settings, values: $model.thenValues) { model.errors(forSetting: $0, step: 1) }
                }
            }
        }
    }

    func followUpLabel(_ ref: TaskRef) -> String {
        (model.models.first { $0.id == ref.recipe }?.name ?? ref.recipe) + " · " + (model.task(ref)?.label ?? ref.task)
    }
}
