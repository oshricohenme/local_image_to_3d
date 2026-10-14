import LiftCore
import SwiftUI

/// The main window: the wizard on first launch, then the sidebar (Generate, Queue, History, Models,
/// Settings) with the server badge, plus the app-wide install sheets (About this model, Hugging
/// Face access), confirmation dialog and alert.
public struct RootView: View {
    @Bindable var app: AppModel
    let onSidebarAppear: ([String]) -> Void

    /// `onSidebarAppear` gets the sidebar's item titles once it's on screen (the launch smoke test uses it).
    public init(app: AppModel, onSidebarAppear: @escaping ([String]) -> Void = { _ in }) {
        self.app = app
        self.onSidebarAppear = onSidebarAppear
    }

    public var body: some View {
        Group {
            switch app.phase {
            case .loading:
                ProgressView("Opening Lift…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .setup:
                SetupView(app: app)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Lift couldn't open its working directory", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Set Up Again") { app.restartSetup() }
                }
            case .ready:
                main
            }
        }
        .sheet(isPresented: Binding(get: { app.aboutBeforeInstall != nil }, set: { if !$0 { app.aboutBeforeInstall = nil } })) {
            if let m = app.aboutBeforeInstall { AboutModelSheet(app: app, model: m) }
        }
        .sheet(isPresented: Binding(get: { app.accessBeforeInstall != nil }, set: { if !$0 { app.accessBeforeInstall = nil } })) {
            if let a = app.accessBeforeInstall { HFAccessSheet(app: app, access: a) }
        }
        .confirmationDialog("Are you sure?", isPresented: Binding(get: { app.confirmation != nil }, set: { if !$0 { app.confirmation = nil } }),
                            presenting: app.confirmation) { c in
            Button(c.action) { Task { await c.confirm() } }  // "Run Anyway" for a memory warning
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
        .alert("Lift", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } }), presenting: app.alert) { _ in
            Button("OK") {}
        } message: { text in
            Text(text)
        }
    }

    var main: some View {
        NavigationSplitView {
            List(AppSection.allCases, selection: Binding(get: { Optional(app.section) }, set: { if let s = $0 { app.section = s } })) { s in
                Label(s.title, systemImage: s.symbol)
                    .badge(s == .queue ? app.queue?.jobs.count ?? 0 : 0)
                    .tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
            .safeAreaInset(edge: .bottom) { serverBadge }
            .onAppear { onSidebarAppear(AppSection.allCases.map(\.title)) }
        } detail: {
            switch app.section {
            case .generate: GenerateView(app: app)
            case .queue: QueueView(app: app)
            case .history: HistoryView(app: app)
            case .models: ModelsView(app: app)
            case .settings: SettingsView(app: app)
            }
        }
    }

    var serverBadge: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(app.serverStatus == nil ? "Server stopped" : "Server running", systemImage: "circle.fill")
                .foregroundStyle(app.serverStatus == nil ? .red : .green)
                .font(.caption.bold())
            if let s = app.serverStatus {
                Text("\(s.bind):\(s.port) · /mcp").font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary)
            }
            // Lift's port changed since an assistant was connected: one click points it at the new one.
            let outdated = app.assistants.needingUpdate
            if !outdated.isEmpty {
                Text("\(outdated.map(\.name).formatted()) still uses Lift's old address.").font(.caption).padding(.top, 6)
                Button("Update Connection") { Task { for a in outdated { await app.assistants.connect(a) } } }.controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }
}

/// Before a model's first install (spec §4a): who made it, the license and any restrictions, the disclaimer,
/// links to the project and its README, then Continue (on to the install's own confirmation).
struct AboutModelSheet: View {
    let app: AppModel
    let model: ModelView

    var body: some View {
        let a = model.recipe.attribution
        VStack(alignment: .leading, spacing: 14) {
            Text("About this model").font(.title2).bold()
            Text("\(a.project) isn't made by Lift. Here is who made it and how you may use it.").foregroundStyle(.secondary)
            ScrollView { AboutView(attribution: a, readme: nil, loadingReadme: false) }
            HStack {
                Link("Open Project Page", destination: a.homepage)
                Link("Read README", destination: a.repo ?? a.homepage)
                Spacer()
                Button("Cancel", role: .cancel) { app.aboutBeforeInstall = nil }
                Button("Continue") { app.continueInstall() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600, height: 500)
    }
}
