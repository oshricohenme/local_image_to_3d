import AppKit
import LiftCore
import SwiftUI

/// The first-launch wizard (spec §11): a welcome, then a step rail (Your files, Your Mac, First model,
/// Access if needed, Done) with Back and Continue. Plain language; logs sit under Show details (spec §1).
struct SetupView: View {
    let app: AppModel
    @State private var model: SetupModel
    @State private var choosing = false
    @State private var choosingExport = false
    @State private var choosingPhoto = false
    @State private var showExport = false
    @Environment(\.openURL) private var openURL

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: SetupModel(app: app, hf: HuggingFaceAccount()))
    }

    var body: some View {
        Group {
            if model.step == .welcome { welcome } else { wizard }
        }
        .font(.system(size: 15))
        .frame(width: 960, height: 660)
        .task { await model.load(app) }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.choose(url) }
        }
    }

    // MARK: welcome

    var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text("Turn photos into 3D models, right on your Mac").font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
            Text("Lift runs free, open-source models made by researchers. Everything happens on this Mac — your photos never leave it.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 560)
            HStack(alignment: .top, spacing: 16) {
                welcomeCard(1, "Choose where Lift keeps its files", "We suggest a spot. Most people keep it.")
                welcomeCard(2, "Let Lift get your Mac ready", "One button. macOS asks for your password once.")
                welcomeCard(3, "Pick your first model", "Big downloads only start when you choose one.")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
            Button("Get Started") { Task { await model.next(app) } }
                .buttonStyle(.borderedProminent).controlSize(.extraLarge).keyboardShortcut(.defaultAction)
            Text("You can stop at any point — Lift picks up where you left off.").font(.callout).foregroundStyle(.secondary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func welcomeCard(_ n: Int, _ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(n)").font(.headline).foregroundStyle(.white).frame(width: 28, height: 28).background(Circle().fill(.tint))
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(width: 240, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(n): \(title). \(detail)")
    }

    // MARK: the wizard

    var wizard: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { content }
                        .padding(40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                footer.padding(.horizontal, 24).padding(.vertical, 14)
            }
        }
    }

    var rail: some View {
        let steps = SetupModel.Step.allCases.filter { $0 != .welcome }
        let current = steps.firstIndex(of: model.step) ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text("Set up Lift").font(.headline).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
            ForEach(Array(steps.enumerated()), id: \.element) { i, s in
                HStack(spacing: 10) {
                    Image(systemName: i < current ? "checkmark.circle.fill" : i == current ? "circle.inset.filled" : "circle")
                        .foregroundStyle(i < current ? AnyShapeStyle(.green) : i == current ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    Text(s.title ?? "").fontWeight(i == current ? .semibold : .regular)
                        .foregroundStyle(i == current ? AnyShapeStyle(.tint) : i < current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                }
                .padding(.vertical, 8).padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(i == current ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityValue(i < current ? "Done" : i == current ? "Current step" : "Not started yet")
            }
            Spacer()
        }
        .padding(16)
        .frame(width: 220)
        .background(.quaternary.opacity(0.35))
    }

    var footer: some View {
        HStack {
            Button("Back") { Task { await model.back(app) } }.keyboardShortcut(.cancelAction).disabled(model.busy)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            switch model.step {
            case .model:
                Button("Skip — I'll choose later") { Task { await model.skipModel(app) } }.buttonStyle(.link)
                let name = model.cards(app).first { $0.id == model.selected }?.name
                primary(name.map { "Install \($0)" } ?? "Install", enabled: name != nil)
            case .access:
                Button("Skip for now") { Task { await model.skipAccess(app) } }.buttonStyle(.link)
                primary("Continue", enabled: model.accessGranted)
            case .mac: primary("Continue", enabled: model.macReady)
            case .done: primary("Start Using Lift", enabled: true)
            default: primary("Continue", enabled: true)
            }
        }
    }

    func primary(_ title: String, enabled: Bool) -> some View {
        Button(title) { Task { await model.next(app) } }
            .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
            .disabled(!enabled || model.busy)
    }

    @ViewBuilder var content: some View {
        switch model.step {
        case .welcome: EmptyView()
        case .files: files
        case .mac: mac
        case .model: firstModel
        case .access: access
        case .done: done
        }
    }

    func heading(_ title: String, _ detail: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 26, weight: .bold)).accessibilityAddTraits(.isHeader)
            if let detail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.bottom, 6)
    }

    func note(_ text: String, systemImage: String, warning: Bool = false) -> some View {
        Label { Text(text).fixedSize(horizontal: false, vertical: true) } icon: {
            Image(systemName: systemImage).foregroundStyle(warning ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((warning ? Color.orange : Color.accentColor).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: your files

    var files: some View {
        Group {
            heading("Where should Lift keep its files?",
                    "Models, results and Lift's own records live in one folder. This spot works for most people.")
            folderCard(model.workdir) { choosing = true }
            if let space = model.space {
                note(space.text, systemImage: space.warning ? "exclamationmark.triangle.fill" : "internaldrive", warning: space.warning)
            }
            DisclosureGroup("Where finished models are saved", isExpanded: $showExport) {
                VStack(alignment: .leading, spacing: 12) {
                    folderCard(model.exportDir) { choosingExport = true }
                    Toggle("Save space: after a model is safely copied there, remove Lift's working copy of it.", isOn: $model.cleanupAfterExport)
                        .toggleStyle(.checkbox)
                }
                .padding(.top, 10)
            }
            .fileImporter(isPresented: $choosingExport, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { model.exportDir = url }
            }
        }
    }

    func folderCard(_ url: URL, change: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill").font(.system(size: 30)).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(SetupModel.friendlyName(url)).font(.headline)
                Text(SetupModel.breadcrumb(url)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Change…", action: change).accessibilityLabel("Change folder: \(SetupModel.friendlyName(url))")
        }
        .padding(16)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: your Mac

    var mac: some View {
        Group {
            heading("Get your Mac ready", "Lift needs a few free tools to download and run models. It installs them for you.")
            if model.prereqs == nil { ProgressView("Checking your Mac…").controlSize(.small) }
            VStack(spacing: 0) {
                ForEach(Array(model.toolRows.enumerated()), id: \.element.name) { i, row in
                    if i > 0 { Divider() }
                    toolRow(row)
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            if let rosetta = model.rosettaNote { note(rosetta, systemImage: "info.circle") }
            if model.installingTools {
                ProgressView { Text("Setting up your Mac. This can take a few minutes.") }.progressViewStyle(.linear)
            }
            if let status = model.macStatus {
                Label(status, systemImage: "checkmark.seal.fill").font(.title3.bold()).foregroundStyle(.green)
            }
            if let failure = model.toolsFailure {
                note("Lift couldn't finish setting up your Mac: \(failure)\nTry again, or open Show details to see what happened.",
                     systemImage: "exclamationmark.triangle.fill", warning: true)
            }
            if model.offerSetUp {
                if model.askPasswordNote {
                    note("Next, macOS will ask for your Mac password once. That's macOS asking, not Lift — Lift never sees it.", systemImage: "lock.fill")
                }
                Button(model.toolsFailure == nil ? "Set Up My Mac" : "Try Again") { Task { await model.setUpMac(app) } }
                    .buttonStyle(.borderedProminent).controlSize(.extraLarge)
            }
            if !model.log.isEmpty {
                DisclosureGroup("Show details") {
                    ScrollView {
                        Text(model.log.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 160)
                }
            }
        }
    }

    func toolRow(_ row: SetupModel.ToolRow) -> some View {
        HStack(spacing: 12) {
            Group {
                switch row.state {
                case .ready: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .needed: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
                case .installing: ProgressView().controlSize(.small)
                case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 22)
            Text("\(Text(row.name).bold()) \(Text("— \(row.detail)").foregroundStyle(.secondary))")
            Spacer()
            Text(stateText(row.state)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    func stateText(_ s: SetupModel.ToolState) -> String {
        switch s {
        case .ready: "Ready"
        case .needed: "Needed"
        case .installing: "Installing…"
        case .failed: "Didn't install"
        }
    }

    // MARK: first model

    var firstModel: some View {
        Group {
            heading("Pick your first model", "Each one is a free, open-source project. You can add others later in Models.")
            ForEach(model.cards(app)) { card in modelCard(card) }
            let addOns = model.addOns(app)
            if !addOns.isEmpty {
                Text("Add-ons, can be added later").font(.headline).padding(.top, 8)
                ForEach(addOns) { a in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Text(a.name).bold()) \(Text("· \(a.task)").foregroundStyle(.secondary))")
                        if let d = a.description { Text(d).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    func modelCard(_ card: SetupModel.ModelCard) -> some View {
        let selected = model.selected == card.id
        return Button { model.selected = card.id } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle").font(.title2)
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(card.name).font(.title3.bold())
                        Text(card.task).font(.callout).padding(.horizontal, 8).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Spacer()
                        if let size = card.size { Text(size).foregroundStyle(.secondary) }
                    }
                    if let d = card.description { Text(d).fixedSize(horizontal: false, vertical: true) }
                    Text(card.credit).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    if !card.gated.isEmpty {
                        Label("Needs a free Hugging Face account", systemImage: "person.badge.key.fill").font(.callout.bold())
                            .padding(.horizontal, 8).padding(.vertical, 3).background(Color.accentColor.opacity(0.12), in: Capsule())
                    }
                    ForEach(card.restrictions, id: \.self) { r in
                        Label(r, systemImage: "exclamationmark.triangle.fill").font(.callout.bold()).foregroundStyle(.orange)
                    }
                    if let why = card.unsupported { Text("Doesn't run on this Mac: \(why)").foregroundStyle(.secondary) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(card.unsupported != nil)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: access

    @ViewBuilder var access: some View {
        if let chosen = model.chosen {
            heading("One more step for \(chosen.name)",
                    "\(chosen.name) uses \(model.accessComponents), whose authors ask you to accept their terms first. It's free.")
            VStack(alignment: .leading, spacing: 0) {
                accessRow(1, "Sign in to or create a free Hugging Face account", status: model.hfUser.map { "Connected as \($0) ✓" }) {
                    Button("Open Hugging Face") { openURL(URL(string: "https://huggingface.co/join")!) }
                }
                ForEach(Array(chosen.gated.enumerated()), id: \.element) { i, repo in
                    Divider()
                    accessRow(2 + i, "Accept the terms for \(repo)", status: model.repoAccess[repo] == true ? "Access granted ✓" : "Waiting") {
                        Button("Open Page") { openURL(URL(string: "https://huggingface.co/\(repo)")!) }
                            .accessibilityLabel("Open the page for \(repo)")
                    }
                }
                Divider()
                accessRow(2 + chosen.gated.count, "Create a key (Hugging Face calls it an access token) — choose “Read”", status: nil) {
                    Button("Open Token Page") { openURL(URL(string: "https://huggingface.co/settings/tokens/new?tokenType=read")!) }
                }
                Divider()
                accessRow(3 + chosen.gated.count, "Paste the key here. Lift keeps it in your Mac's Keychain.", status: nil) {
                    HStack {
                        SecureField("hf_…", text: $model.hfToken).frame(width: 240).accessibilityLabel("Hugging Face key")
                            .onSubmit { Task { await model.checkToken(app) } }
                        Button("Check") { Task { await model.checkToken(app) } }
                    }
                    .fixedSize()
                }
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
            if let user = model.hfUser { Label("Connected as \(user) ✓", systemImage: "person.crop.circle.badge.checkmark").foregroundStyle(.green) }
            if let problem = model.tokenProblem { note(problem, systemImage: "exclamationmark.triangle.fill", warning: true) }
            if model.hfUser != nil && !model.accessGranted {
                Text("After accepting the terms on each page, press Check again.").foregroundStyle(.secondary)
            }
        }
    }

    func accessRow(_ n: Int, _ title: String, status: String?, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 12) {
            Text("\(n)").font(.headline).foregroundStyle(.white).frame(width: 26, height: 26).background(Circle().fill(.tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if let status {
                    Text(status).font(.callout).foregroundStyle(status.hasSuffix("✓") ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Step \(n): \(title)\(status.map { ". \($0)" } ?? "")")
            Spacer()
            action()
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: done

    var done: some View {
        Group {
            heading("You're all set", nil)
            VStack(spacing: 12) {
                Image(systemName: "photo.badge.plus").font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
                Text("Drop a photo of an object to make your first 3D model").font(.title3.bold()).multilineTextAlignment(.center)
                Button("Choose a Photo…") { choosingPhoto = true }
            }
            .frame(maxWidth: .infinity, minHeight: 200)
            .background(RoundedRectangle(cornerRadius: 14).strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
            .dropDestination(for: URL.self) { urls, _ in
                model.drop(urls, app)
                return app.phase == .ready
            }
            .fileImporter(isPresented: $choosingPhoto, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result { model.drop([url], app) }
            }
            if let status = model.installStatus(app), let chosen = model.chosen {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        if case .installing = app.models.first(where: { $0.id == chosen.id })?.status { ProgressView().controlSize(.small) }
                        Text(status)
                        if case .notInstalled = app.models.first(where: { $0.id == chosen.id })?.status, chosen.gated.isEmpty || model.accessGranted {
                            Button("Install \(chosen.name)") { model.install(app) }
                        }
                    }
                    if let m = app.models.first(where: { $0.id == chosen.id }) {
                        Text(Credits.madeWith(m.recipe.attribution)).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("Use Lift from an AI assistant (optional)") {
                VStack(alignment: .leading, spacing: 8) { assistant }.padding(.top, 8)
            }
        }
    }

    @ViewBuilder var assistant: some View {
        if let s = app.serverStatus {
            Text("AI assistants such as Claude Code can use Lift too. To connect Claude Code, run this once in Terminal:")
            snippet("claude mcp add --transport http lift \(s.urls.mcp)")
            if let entry = s.mcpConfig["mcpServers"]?["lift"], let command = entry.command {
                Text("Assistants that start a program instead of using a web address can run:")
                snippet(([command] + (entry.args ?? [])).joined(separator: " "))
            }
        } else {
            Text("Lift's assistant connection didn't start. Settings shows why, and the command once it's running.")
        }
    }

    func snippet(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .accessibilityLabel("Copy command")
        }
    }
}
