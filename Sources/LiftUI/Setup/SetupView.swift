import AppKit
import LiftCore
import SwiftUI

/// Setup (spec §11): only the steps for what's missing, on a step rail with Back and Continue. A first run
/// adds the welcome and "You're all set". Plain language; logs sit under Show details (spec §1).
struct SetupView: View {
    let app: AppModel
    @State private var model: SetupModel
    @State private var choosing = false
    @State private var choosingExport = false
    @State private var showExport = false

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: SetupModel(app: app))
    }

    var body: some View {
        Group {
            if model.step == .welcome { welcome } else { wizard }
        }
        .font(.system(size: 15))
        .frame(minWidth: 860, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)  // fills a resized window
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.choose(url) }
        }
    }

    // MARK: welcome

    var welcome: some View {
        VStack(spacing: 22) {
            Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 96, height: 96).accessibilityHidden(true)
            Text(model.heading).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
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
        let steps = model.steps.filter { $0 != .welcome }
        let current = steps.firstIndex(of: model.step) ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            Text(model.railTitle).font(.headline).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 10)
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
            if model.canGoBack {
                Button("Back") { Task { await model.back(app) } }.keyboardShortcut(.cancelAction).disabled(model.busy)
            }
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            switch model.step {
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
            if model.firstRun {
                heading(model.heading, "Models, results and Lift's own records live in one folder. This spot works for most people.")
            } else {
                heading(model.heading, "Lift can't open the folder it used before. It may have been moved, renamed or deleted. "
                        + "Choose where Lift should keep its files; the same spot starts it afresh there.")
            }
            folderCard(model.workdir) { choosing = true }
            if let problem = model.workdirProblem {
                LocalDisclosure("Show details") { Text(problem).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            }
            if let space = model.space {
                note(space.text, systemImage: space.warning ? "exclamationmark.triangle.fill" : "internaldrive", warning: space.warning)
            }
            Disclosure("Where finished models are saved", isExpanded: $showExport) {
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
            heading(model.heading, model.firstRun ? "Lift needs a few free tools to download and run models. It installs them for you."
                    : "Lift needs these free tools to download and run models. It puts back what's missing for you.")
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
                LocalDisclosure("Show details") {
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

    // MARK: done

    var done: some View {
        Group {
            heading("You're all set", "Lift is ready. Next, pick a model in Models: Lift installs it and walks you through anything it needs.")
            assistants
        }
    }

    /// Optional and off by default: nothing is connected until a click, and Start Using Lift never waits for it.
    var assistants: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use Lift from an AI assistant (optional)").font(.headline)
            Text("Claude or Codex can use Lift to make 3D models for you. Connect one now or later in Settings.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if app.serverStatus == nil {
                Text("Lift's assistant connection didn't start. Settings shows why.").foregroundStyle(.secondary)
            } else {
                AssistantRows(app: app, installedOnly: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .task(id: app.serverStatus?.urls.mcp) { app.checkAssistants() }
    }
}
