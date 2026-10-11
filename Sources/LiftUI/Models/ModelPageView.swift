import AppKit
import LiftCore
import SwiftUI

/// What the model page's action card shows, from the model's status and its download.
public enum ModelPage {
    public enum Action: Equatable, Sendable {
        case notInstalled, installing, downloading
        case ready(updateAvailable: Bool)
        case failed(String)
        case unsupported(String)
    }

    public static func action(_ m: ModelView) -> Action {
        if let d = m.download {
            if d.state.isActive { return .downloading }
            if d.state == .failed { return .failed(d.reason ?? "The download stopped.") }
            if d.state == .cancelled { return .failed("The download was stopped. What's downloaded so far is kept, so it picks up from there.") }
        }
        switch m.status {
        case .notInstalled: return .notInstalled
        case .installing: return .installing
        case .installed: return .ready(updateAvailable: false)
        case .updateAvailable: return .ready(updateAvailable: true)
        case .installFailed: return .failed("The install stopped at a step that failed. The install log has the details.")
        case .weightsMissing: return .failed("Some of the model's files are missing. Download them again to fix it.")
        case .weightsCorrupt: return .failed("Some of the model's files are damaged. Download them again to fix it.")
        case .unsupported(let reason): return .unsupported(reason)
        }
    }
}

/// A model's page (the approved redesign): the hero (preview, name, description, credit, links), one action card
/// that follows its state, then what it's good at and its README beside Before you start, Credits & licenses
/// and, in developer mode, the details. Scrolls as one; the columns stack in a narrow window.
struct ModelPageView: View {
    let app: AppModel
    let id: String
    let back: () -> Void
    @State private var detail: ModelView?
    @State private var readme: Readme?
    @State private var loadingReadme = false
    @State private var note: String?
    @State private var pinning = false
    @State private var pin = ""
    @State private var access: HFAccess?
    /// The page's width: below ~900 pt (840 inside the padding) the columns stack, below ~800 the hero too.
    @State private var width: CGFloat = 1000

    var body: some View {
        ScrollView {
            if let m = app.models.first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 20) {
                    Button(action: back) { Label("All models", systemImage: "chevron.left") }.buttonStyle(.link)
                    hero(m)
                    actionCard(m)
                    if width >= 840 {
                        HStack(alignment: .top, spacing: 24) {
                            main(m).frame(maxWidth: .infinity, alignment: .leading)
                            side(m).frame(width: 340)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 24) {
                            main(m)
                            side(m)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width - 48 }) { width = $0 }
            } else {
                ContentUnavailableView("This model isn't available any more", systemImage: "shippingbox")
            }
        }
        .navigationTitle(app.models.first { $0.id == id }?.name ?? "Model")
        .task(id: id) {
            await loadDetail()
            if let m = app.models.first(where: { $0.id == id }) {
                await app.loadPreview(m)
                await app.loadWeightBytes(m)
            }
            loadingReadme = true
            readme = try? await app.lift?.modelsReadme(id)
            loadingReadme = false
        }
        .onChange(of: app.models.first { $0.id == id }?.status) { Task { await loadDetail() } }
        .sheet(item: Binding(get: { access.map { AccessBox(access: $0) } }, set: { if $0 == nil { access = nil } })) { box in
            VStack(alignment: .leading, spacing: 14) {
                Text("Hugging Face").font(.title2).bold()
                ScrollView { HFAccessView(app: app, access: box.access) }
                HStack { Spacer(); Button("Done") { access = nil }.keyboardShortcut(.defaultAction) }
            }
            .padding(20)
            .frame(minWidth: 560, minHeight: 440)
        }
        .alert("Change version", isPresented: $pinning) {
            TextField("40-character commit", text: $pin)
            Button("Reinstall at this commit") {
                let commit = pin
                app.gated { confirm in try await app.engine.modelsSetPin(id, commit: commit, confirm: confirm) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    struct AccessBox: Identifiable {
        let access: HFAccess
        var id: ObjectIdentifier { ObjectIdentifier(access) }
    }

    func loadDetail() async {
        detail = try? await app.lift?.modelsGet(id)
    }

    // MARK: hero

    func hero(_ m: ModelView) -> some View {
        let a = m.recipe.attribution
        let card = ModelCard(m, weightsBytes: m.download?.totalBytes ?? app.weightBytes[m.id])
        let info = VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(m.name).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                Text(card.task).font(.callout).padding(.horizontal, 8).padding(.vertical, 2).background(.quaternary, in: Capsule())
            }
            if let d = m.recipe.description { Text(d).fixedSize(horizontal: false, vertical: true) }
            Text("Created by \(a.authors.joined(separator: ", ")) · \(a.license.spdx) license").foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link("Project page ↗", destination: a.homepage)
                if let paper = a.paper { Link("Read the paper ↗", destination: paper.url) }
                if let repo = a.repo { Link("Source code ↗", destination: repo) }
            }
        }
        return Group {
            if width >= 740 {
                HStack(alignment: .top, spacing: 24) {
                    PreviewImage(url: app.previews[m.id], symbol: taskSymbol(m)).frame(width: 380, height: 236).clipShape(RoundedRectangle(cornerRadius: 12))
                    info.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    PreviewImage(url: app.previews[m.id], symbol: taskSymbol(m)).frame(height: 200).frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    info
                }
            }
        }
    }

    // MARK: action card

    func actionCard(_ m: ModelView) -> some View {
        let card = ModelCard(m, weightsBytes: m.download?.totalBytes ?? app.weightBytes[m.id])
        return VStack(alignment: .leading, spacing: 10) {
            switch ModelPage.action(m) {
            case .notInstalled:
                Text((card.size.map { "Downloads \($0.lowercased())." } ?? "") + " You can keep using Lift while it downloads.")
                Button("Install \(m.name)") { app.install(m) }.buttonStyle(.borderedProminent).controlSize(.large)
            case .installing:
                InstallProgressRow(app: app, model: m)
                Button("Cancel") { app.run { _ = try await app.engine.modelsCancelInstall(m.id) } }
                    .help("Stops the install. Nothing is marked failed; Install starts it again.")
            case .downloading:
                DownloadControls(app: app, model: m)
                CardActionButton(app: app, model: m)  // Download now, while it waits
            case .ready(let update):
                let disk = (detail?.diskBytes).map { " · \(Format.bytes($0)) on disk" } ?? ""
                Text("Ready ✓" + disk + " · " + (update ? "update available" : "up to date")).font(.headline)
                HStack {
                    Button("Use in Generate") { app.useInGenerate(m) }.buttonStyle(.borderedProminent).controlSize(.large)
                    Menu {
                        if m.recipe.repo != nil { Button("Check for Updates") { checkUpstream(m) } }
                        Button(update ? "Update (Reinstall)" : "Reinstall") { app.gated { confirm in try await app.engine.modelsReinstall(m.id, confirm: confirm) } }
                        if !m.recipe.weights.isEmpty {
                            Button("Check the Files") { app.run { _ = try await app.engine.modelsVerifyWeights(m.id) } }
                            Button("Download the Files Again…") { app.gated { confirm in try await app.engine.modelsDownloadWeights(m.id, confirm: confirm) } }
                        }
                        Button("Reveal in Finder") {
                            if let workdir = app.workdir { NSWorkspace.shared.activateFileViewerSelecting([workdir.appending(path: "models/\(m.id)")]) }
                        }
                        Divider()
                        Button("Uninstall…", role: .destructive) { app.gated { confirm in try await app.engine.modelsUninstall(m.id, confirm: confirm) } }
                    } label: {
                        Label("More", systemImage: "ellipsis")
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("More actions")
                }
            case .failed(let reason):
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if let link = m.download?.link { Link("Open the terms page", destination: link) }
                Button("Try Again") {
                    if case .installFailed = m.status, m.download == nil { app.install(m) } else { retry(app, m) }
                }
                .buttonStyle(.borderedProminent)
            case .unsupported(let reason):
                Label("Doesn't run on this Mac: \(reason)", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
    }

    func checkUpstream(_ m: ModelView) {
        app.run {
            let u = try await app.engine.modelsCheckUpstream(m.id)
            note = switch u.commitsAhead {
            case 0?: "The project hasn't changed since this version."
            case let n?: "The project has \(n) newer change\(n == 1 ? "" : "s") since this version."
            case nil: "The project's latest version is \(u.head.prefix(7))."
            }
        }
    }

    // MARK: columns

    func main(_ m: ModelView) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let d = m.recipe.description {
                section("What it's good at") { Text(d).fixedSize(horizontal: false, vertical: true) }
            }
            section("About the project") {
                if let readme {
                    Text(readme.cached ? "From the authors' README on GitHub (a saved copy: Lift couldn't reach the internet)."
                         : "From the authors' README on GitHub").font(.caption).foregroundStyle(.secondary)
                    ReadmeView(readme: readme)
                } else if loadingReadme {
                    ProgressView().controlSize(.small)
                } else {
                    Text("The project's README isn't available right now.").foregroundStyle(.secondary)
                }
            }
        }
    }

    func side(_ m: ModelView) -> some View {
        let card = ModelCard(m, weightsBytes: nil)
        let a = m.recipe.attribution
        return VStack(alignment: .leading, spacing: 20) {
            if !card.gated.isEmpty || !card.restrictions.isEmpty {
                section("Before you start") {
                    if !card.gated.isEmpty {
                        HStack {
                            Label(app.secrets.get(.hfToken) == nil ? "Needs a free Hugging Face account" : "Hugging Face key saved",
                                  systemImage: "person.badge.key.fill")
                            Spacer()
                            Button("Manage…") { access = HFAccess(m) }
                        }
                    }
                    ForEach(card.restrictions, id: \.self) { r in
                        Label(r, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            section("Credits & licenses") {
                HStack(alignment: .firstTextBaseline) {
                    Text(a.project).bold()
                    Link(a.license.spdx, destination: a.license.url)
                }
                ForEach(a.components.indices, id: \.self) { i in
                    let c = a.components[i]
                    VStack(alignment: .leading, spacing: 1) {
                        Link(c.name, destination: c.url)
                        HStack(spacing: 4) {
                            Text(c.role).foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.secondary)
                            Link(c.license.spdx, destination: c.license.url)
                        }
                        if !c.restrictions.isEmpty { Text(c.restrictions.joined(separator: "; ")).foregroundStyle(.orange) }
                    }
                    .font(.callout)
                    .padding(c.restrictions.isEmpty ? 0 : 6)
                    .background(c.restrictions.isEmpty ? Color.clear : Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
                if let bibtex = a.paper?.bibtex {
                    LocalDisclosure("Cite this work (BibTeX)") {
                        Text(bibtex).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy BibTeX") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bibtex, forType: .string)
                        }
                    }
                }
                Text(a.disclaimer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if app.developer {
                LocalDisclosure("Details for developers") { developer(m) }
            }
        }
    }

    func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: developer details

    @ViewBuilder func developer(_ m: ModelView) -> some View {
        let r = m.recipe
        VStack(alignment: .leading, spacing: 12) {
            facts([
                ("Pinned commit", m.pin ?? "—"), ("Repository", r.repo ?? "bundled with Lift"), ("Recipe source", m.source ?? "installed copy only"),
                ("Python", r.python), ("Memory", "\(r.resources.memoryGB.formatted()) GB estimate"),
                ("Disk", (detail?.diskBytes).map(Format.bytes) ?? "—"),
            ] + (r.brew.isEmpty ? [] : [("Homebrew packages", r.brew.joined(separator: ", "))]))
            HStack {
                if r.repo != nil { Button("Check Upstream") { checkUpstream(m) } }
                Button("Change Version…") { pin = m.pin ?? ""; pinning = true }
            }
            if !r.weights.isEmpty {
                Text("Weights").font(.headline)
                ForEach(r.weights, id: \.repo) { w in
                    Text("\(w.repo)@\(w.revision)\(w.gated ? " · gated" : "")").font(.system(.caption, design: .monospaced))
                }
                if let report = m.weights {
                    Text("Last check: \(report.state.rawValue) · \(report.checkedAt.formatted())\(report.note.map { " · " + $0 } ?? "")").font(.caption)
                    ForEach(report.problems.indices, id: \.self) { i in
                        let p = report.problems[i]
                        Text("\(p.repo)/\(p.path): \(p.issue.rawValue)\(p.detail.map { " (\($0))" } ?? "")").font(.caption).foregroundStyle(.red)
                    }
                }
            }
            Text("Install steps").font(.headline)
            ForEach(Array(installSteps(m).enumerated()), id: \.offset) { i, step in
                Text("\(i + 1). \(step)").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Text("Mac shim").font(.headline)
            shim(r)
            Text("Options").font(.headline)
            options(r)
            LocalDisclosure("Install log") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(logText() ?? "No install log yet.").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    func facts(_ rows: [(String, String)]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    Text(rows[i].0).foregroundStyle(.secondary)
                    Text(rows[i].1).textSelection(.enabled)
                }
            }
        }
        .font(.caption)
    }

    func installSteps(_ m: ModelView) -> [String] {
        let r = m.recipe
        var steps: [String] = r.brew.isEmpty ? [] : ["brew install \(r.brew.joined(separator: " "))"]
        if let repo = r.repo { steps.append("git clone --filter=blob:none \(repo) repo && git -C repo checkout \(m.pin ?? r.commit ?? "")") }
        steps.append("uv venv --python \(r.python) venv")
        steps += r.install
        if !r.substitutes.isEmpty { steps.append("substitutes: \(r.substitutes.joined(separator: ", "))") }
        if r.shim != nil { steps.append("uv pip install lift_shim + .pth") }
        steps.append("python -m lift_worker --check (smoke import)")
        return steps
    }

    @ViewBuilder func shim(_ r: Recipe) -> some View {
        if let shim = r.shim {
            facts([
                ("Device remap", ".cuda(), .to(\"cuda\"), torch.cuda.* → mps"),
                ("Attention", "flash_attn → PyTorch SDPA (ATTN_BACKEND=sdpa)"),
                ("Substitutes", r.substitutes.isEmpty ? "none" : r.substitutes.joined(separator: ", ")),
                ("Aliases", shim.aliases.isEmpty ? "none" : shim.aliases.map { "\($0.key) → \($0.value)" }.sorted().joined(separator: "\n")),
                ("Stand-ins", shim.standins.isEmpty ? "none" : shim.standins.joined(separator: ", ")),
                ("Patches", shim.patches.isEmpty ? "none" : shim.patches.joined(separator: ", ")),
                ("Environment", shim.env.isEmpty ? "none" : shim.env.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "\n")),
            ])
        } else {
            Text("A Mac port already: no lift_shim.").font(.caption).foregroundStyle(.secondary)
        }
    }

    func options(_ r: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(r.tasks, id: \.id) { t in
                Text(t.label).font(.caption.bold())
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    ForEach(t.settings, id: \.key) { s in
                        GridRow {
                            Text(s.key).font(.system(.caption, design: .monospaced))
                            Text(s.type.rawValue).font(.caption)
                            Text(s.default?.description ?? "—").font(.caption)
                        }
                    }
                }
            }
        }
    }

    /// Read straight from `models/<id>/install.log` so the live view needs no actor hop per tick.
    func logText() -> String? {
        guard let workdir = app.workdir else { return nil }
        return try? String(contentsOf: workdir.appending(path: "models/\(id)/install.log"), encoding: .utf8)
    }
}
