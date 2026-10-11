import AppKit
import LiftCore
import SwiftUI

enum ModelTab: String, CaseIterable {
    case about = "About", overview = "Overview", options = "Options", install = "Install", shim = "Mac shim"
}

/// Recipes grouped by the modalities of their tasks (a recipe can appear in several groups).
enum ModelGroups {
    static func by(_ models: [ModelView]) -> [(modality: String, models: [ModelView])] {
        GenerateModel.modalities.map { id, _ in (id, models.filter { m in m.recipe.tasks.contains { $0.modality == id } }) }
    }
}

/// Models (mockup Models.dc.html): recipes by modality, and per recipe Overview and Install (weights
/// download and verify, the install log under Details) with install, reinstall, uninstall and check upstream.
/// Developer mode adds Options (raw setting keys), the install commands, Change Pin and the Mac shim
/// (spec §1: the developer view is opt-in). Recipes come only from Lift (spec §4): no sources to add.
struct ModelsView: View {
    let app: AppModel
    @State private var selected: String?
    @State private var tab = ModelTab.about
    @State private var detail: ModelView?
    @State private var note: String?
    @State private var listings: [RecipeListing] = []
    @State private var pinning = false
    @State private var pin = ""
    @State private var readme: Readme?
    @State private var loadingReadme = false
    /// Weight sizes Hugging Face reported, by model id.
    @State private var weightBytes: [String: Int] = [:]

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                ForEach(ModelGroups.by(app.models), id: \.modality) { group in
                    Section("\(GenerateModel.modalities.first { $0.0 == group.modality }?.1 ?? group.modality) · \(group.models.count)") {
                        ForEach(group.models, id: \.id) { row($0) }
                    }
                }
                let problems = listings.filter { $0.state != .available && $0.state != .developerHidden }
                if !problems.isEmpty {
                    Section("Recipes Lift can't use") {
                        ForEach(problems.indices, id: \.self) { i in
                            let l = problems[i]
                            Text("\(l.name ?? l.id): \(problemText(l))").font(.caption)
                        }
                    }
                }
            }
            .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            detailPane.frame(minWidth: 480, maxWidth: .infinity)
        }
        .navigationTitle("Models")
        .task(id: app.models.count) { listings = await app.lift?.recipesList() ?? [] }
        .task(id: selected) { await loadDetail(); await loadReadme(); await loadSize() }
        .onChange(of: app.models) { Task { await loadDetail() } }
        .onChange(of: app.developer) { if !app.developer && !tabs.contains(tab) { tab = .about } }
        .alert("Change pin", isPresented: $pinning) {
            TextField("40-character commit", text: $pin)
            Button("Reinstall at this commit") {
                guard let id = selected else { return }
                let commit = pin
                app.gated { confirm in try await app.engine.modelsSetPin(id, commit: commit, confirm: confirm) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    func row(_ m: ModelView) -> some View {
        VStack(alignment: .leading) {
            Text(m.name).bold()
            Text(Format.status(m.status) + (app.developer ? m.pin.map { " · @" + $0.prefix(7) } ?? "" : "")).font(.caption)
        }
        .foregroundStyle(m.isUnsupported ? .secondary : .primary)
        .tag(m.id)
    }

    func loadDetail() async {
        guard let id = selected, let lift = app.lift else { detail = nil; return }
        detail = try? await lift.modelsGet(id)
    }

    func loadReadme() async {
        readme = nil
        guard let id = selected, let lift = app.lift else { return }
        loadingReadme = true
        defer { loadingReadme = false }
        readme = try? await lift.modelsReadme(id)
    }

    func loadSize() async {
        guard let m = detail, weightBytes[m.id] == nil, !m.recipe.weights.isEmpty else { return }
        if let bytes = await app.hf.size(of: m.recipe.weights) { weightBytes[m.id] = bytes }
    }

    func problemText(_ l: RecipeListing) -> String {
        switch l.state {
        case .needsNewerLift: "needs a newer version of Lift"
        case .invalid: "the recipe has a mistake" + (app.developer ? " (\(l.detail ?? ""))" : "")
        case .shadowed: "your edited copy is used instead"
        case .available, .developerHidden: ""
        }
    }

    var tabs: [ModelTab] { app.developer ? ModelTab.allCases : [.about, .overview, .install] }

    @ViewBuilder var detailPane: some View {
        if let m = detail {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading) {
                        Text(m.name).font(.title2).bold()
                        Text("by " + m.recipe.attribution.authors.joined(separator: ", ") + " · " + m.recipe.attribution.license.spdx).foregroundStyle(.secondary)
                        if let d = m.recipe.description { Text(d).font(.callout) }
                        let card = ModelCard(m, weightsBytes: weightBytes[m.id])
                        if let size = card.size { Text(size).font(.callout).foregroundStyle(.secondary) }
                        if !card.gated.isEmpty {
                            Label("Needs a free Hugging Face account", systemImage: "person.badge.key.fill").font(.callout.bold())
                        }
                        ForEach(card.restrictions, id: \.self) { r in
                            Label(r, systemImage: "exclamationmark.triangle.fill").font(.callout.bold()).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    actions(m)
                }
                if case .unsupported(let reason) = m.status {
                    Label("Unsupported on this Mac: \(reason)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
                Picker("Section", selection: $tab) {
                    ForEach(tabs, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                ScrollView {
                    switch tab {
                    case .about: AboutView(attribution: m.recipe.attribution, readme: readme, loadingReadme: loadingReadme)
                    case .overview: overview(m)
                    case .options: options(m)
                    case .install: install(m)
                    case .shim: shim(m)
                    }
                }
            }
            .padding()
        } else {
            ContentUnavailableView("Select a recipe", systemImage: "shippingbox")
        }
    }

    @ViewBuilder func actions(_ m: ModelView) -> some View {
        HStack {
            switch m.status {
            case .notInstalled, .installFailed:
                Button("Install") { app.install(m) }
                    .buttonStyle(.borderedProminent)
            case .installing:
                ProgressView().controlSize(.small)
            case .unsupported:
                EmptyView()
            default:
                if app.developer { Button("Change Pin…") { pin = m.pin ?? ""; pinning = true } }
                Button("Reinstall") { app.gated { confirm in try await app.engine.modelsReinstall(m.id, confirm: confirm) } }
                Button("Reveal in Finder") {
                    if let workdir = app.workdir { NSWorkspace.shared.activateFileViewerSelecting([workdir.appending(path: "models/\(m.id)")]) }
                }
                Button("Uninstall", role: .destructive) { app.gated { confirm in try await app.engine.modelsUninstall(m.id, confirm: confirm) } }
            }
            if m.recipe.repo != nil {
                Button("Check Upstream") {
                    app.run {
                        let u = try await app.engine.modelsCheckUpstream(m.id)
                        note = "Upstream head \(u.head.prefix(7))" + (u.commitsAhead.map { " · \($0) commits past the pin" } ?? "")
                    }
                }
            }
        }
    }

    func facts(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).foregroundStyle(.secondary)
                    Text(rows[i].1).textSelection(.enabled)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func overview(_ m: ModelView) -> some View {
        let r = m.recipe
        var rows: [(String, String)] = [
            ("Made by", r.attribution.authors.joined(separator: ", ")),
            ("License", r.attribution.license.spdx),
            ("Project page", r.attribution.homepage.absoluteString),
            ("Tasks", r.tasks.map { "\($0.label) (\($0.inputs.map(\.type.rawValue).joined(separator: ", ")) → \($0.output.rawValue))" }.joined(separator: "\n")),
            ("Python", "\(r.python) · its own environment, separate from the rest of the Mac"),
            ("Memory", "\(r.resources.memoryGB.formatted()) GB estimate" + r.resources.memoryOverrides.map { o in
                " · \(o.memoryGB.formatted()) GB when \(o.when.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))"
            }.joined()),
            ("Disk", m.diskBytes.map(Format.bytes) ?? "—"),
        ]
        if !r.brew.isEmpty { rows.append(("Homebrew packages", r.brew.joined(separator: ", "))) }
        if app.developer {
            rows += [("Recipe source", m.source ?? "installed copy only"), ("Repository", r.repo ?? "bundled with Lift"), ("Pinned commit", m.pin ?? "—")]
        }
        return VStack(alignment: .leading, spacing: 10) {
            facts(rows)
            Text(r.attribution.disclaimer).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical)
    }

    func options(_ m: ModelView) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Generated from the recipe's option list. Jobs that don't set an option get its default.").font(.caption).foregroundStyle(.secondary)
            ForEach(m.recipe.tasks, id: \.id) { t in
                Text(t.label).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { Text("Option").bold(); Text("Key").bold(); Text("Type").bold(); Text("Default").bold(); Text("Shown").bold() }
                    ForEach(t.settings, id: \.key) { s in
                        GridRow {
                            Text(s.label)
                            Text(s.key).font(.system(.body, design: .monospaced))
                            Text(typeText(s))
                            Text(s.default?.description ?? "—")
                            Text((s.group ?? "basic").capitalized)
                        }
                    }
                }
            }
        }
        .padding(.vertical)
    }

    func typeText(_ s: SettingDef) -> String {
        var t = s.type.rawValue
        if let o = s.options { t += " " + o.map(\.description).joined(separator: " | ") }
        if s.min != nil || s.max != nil { t += " \(s.min?.formatted() ?? "")–\(s.max?.formatted() ?? "")" }
        return t
    }

    func install(_ m: ModelView) -> some View {
        let r = m.recipe
        var steps: [String] = r.brew.isEmpty ? [] : ["brew install \(r.brew.joined(separator: " "))"]
        if let repo = r.repo { steps.append("git clone --filter=blob:none \(repo) repo && git -C repo checkout \(m.pin ?? r.commit ?? "")") }
        steps.append("uv venv --python \(r.python) venv")
        steps += r.install
        if !r.substitutes.isEmpty { steps.append("substitutes: \(r.substitutes.joined(separator: ", "))") }
        if r.shim != nil { steps.append("uv pip install lift_shim + .pth") }
        steps.append("python -m lift_worker --check (smoke import)")
        return VStack(alignment: .leading, spacing: 10) {
            Text("Installing downloads the project's code and sets up its own Python environment (about \(r.resources.diskGB.formatted()) GB). "
                 + "It runs once; Reinstall repeats it.").font(.caption).foregroundStyle(.secondary)
            if app.developer {
                ForEach(steps.indices, id: \.self) { i in
                    Text("\(i + 1). \(steps[i])").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
            }
            weights(m)
            DisclosureGroup("Details: install log") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text((try? logText(m.id)) ?? "No install log yet.").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical)
    }

    /// Read straight from `models/<id>/install.log` so the live view needs no actor hop per tick.
    func logText(_ id: String) throws -> String {
        guard let workdir = app.workdir else { return "" }
        return try String(contentsOf: workdir.appending(path: "models/\(id)/install.log"), encoding: .utf8)
    }

    @ViewBuilder func weights(_ m: ModelView) -> some View {
        if !m.recipe.weights.isEmpty {
            Text("Weights").font(.headline)
            Text("Downloaded only when you press Download, into the shared Hugging Face cache; checked before every worker start.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(m.recipe.weights, id: \.repo) { w in
                Text("\(w.repo)@\(w.revision)\(w.gated ? " · gated, needs a Hugging Face token" : "")").font(.system(.callout, design: .monospaced))
            }
            if let report = m.weights {
                Text("Last check: \(report.state.rawValue) · \(report.checkedAt.formatted())\(report.note.map { " · " + $0 } ?? "")").font(.callout)
                ForEach(report.problems.indices, id: \.self) { i in
                    let p = report.problems[i]
                    Text("\(p.repo)/\(p.path): \(p.issue.rawValue)\(p.detail.map { " (\($0))" } ?? "")").font(.caption).foregroundStyle(.red)
                }
            }
            HStack {
                Button("Download Weights…") { app.gated { confirm in try await app.engine.modelsDownloadWeights(m.id, confirm: confirm) } }
                    .disabled(!m.isInstalled && !isWeightsProblem(m))
                Button("Verify Weights") { app.run { _ = try await app.engine.modelsVerifyWeights(m.id) } }
            }
        }
    }

    func isWeightsProblem(_ m: ModelView) -> Bool {
        switch m.status {
        case .weightsMissing, .weightsCorrupt: true
        default: false
        }
    }

    func shim(_ m: ModelView) -> some View {
        let r = m.recipe
        return VStack(alignment: .leading, spacing: 10) {
            if let shim = r.shim {
                Text("CUDA isn't available on this Mac, so Lift loads its shared cuda→mps shim before the project's code. Nothing in the cloned repo is edited.")
                    .font(.caption).foregroundStyle(.secondary)
                facts([
                    ("Device remap", ".cuda(), .to(\"cuda\"), torch.cuda.* → mps"),
                    ("Attention", "flash_attn → PyTorch SDPA (ATTN_BACKEND=sdpa)"),
                    ("CPU fallback", "PYTORCH_ENABLE_MPS_FALLBACK=1"),
                    ("Substitutes", r.substitutes.isEmpty ? "none" : r.substitutes.joined(separator: ", ")),
                    ("Aliases", shim.aliases.isEmpty ? "none" : shim.aliases.map { "\($0.key) → \($0.value)" }.sorted().joined(separator: "\n")),
                    ("Stand-ins", shim.standins.isEmpty ? "none" : shim.standins.joined(separator: ", ")),
                    ("Patches", shim.patches.isEmpty ? "none" : shim.patches.joined(separator: ", ")),
                    ("Environment", shim.env.isEmpty ? "none" : shim.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")),
                ])
            } else {
                Text("This recipe runs as a Mac port already and doesn't use lift_shim.").foregroundStyle(.secondary)
            }
        }
        .padding(.vertical)
    }
}
