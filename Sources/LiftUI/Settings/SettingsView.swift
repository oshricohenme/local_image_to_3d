import AppKit
import LiftCore
import LiftServer
import SwiftUI

/// Settings (mockup Settings.dc.html + spec §11, §12): server and MCP, LAN access and token, queue and
/// workers with learned estimates, app behavior, storage, Hugging Face token, toolchain, developer.
struct SettingsView: View {
    let app: AppModel
    @State private var port = ""
    @State private var hfToken = ""
    @State private var showToken = false
    @State private var token: String?
    @State private var prereqs: Prereqs?
    @State private var toolLog: [String] = []
    @State private var choosingWorkdir = false
    @State private var choosingExportDir = false

    var body: some View {
        Form {
            server
            lan
            queue
            app_
            storage
            accounts
            toolchain
            Section("Developer") {
                toggle("Developer mode: the Test Cube, recipe settings, commits and the Mac shim", "dev_recipes", app.settings.devRecipes)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .onAppear { port = app.serverStatus.map { String($0.configuredPort) } ?? "" }
        .task {
            token = await app.server?.lanToken()
            prereqs = await app.lift?.systemPrereqs(checkMetal: app.needsMetalToolchain)
        }
        .fileImporter(isPresented: $choosingWorkdir, allowedContentTypes: [.folder]) { result in
            if case .success(let parent) = result, let current = app.workdir {
                app.moveWorkdir(to: parent.appending(path: current.lastPathComponent))
            }
        }
    }

    func toggle(_ label: String, _ key: String, _ value: Bool) -> some View {
        Toggle(label, isOn: Binding(get: { value }, set: { on in app.run { _ = try await app.engine.settingsSet(key, .bool(on)) } }))
    }

    func copyRow(_ label: String, _ text: String) -> some View {
        LabeledContent(label) {
            HStack {
                Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                Button("Copy") { copy(text) }
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: sections

    @ViewBuilder var server: some View {
        Section("HTTP API and MCP") {
            if let s = app.serverStatus {
                LabeledContent("Listening", value: "\(s.bind):\(s.port)" + (s.port != s.configuredPort ? " (\(s.configuredPort) was taken)" : ""))
                copyRow("Base URL", s.urls.api)
                Link("Open API reference", destination: URL(string: s.urls.docs)!)
                copyRow("Claude Code", "claude mcp add --transport http lift \(s.urls.mcp)")
                if let entry = s.mcpConfig["mcpServers"]?["lift"], let command = entry.command {
                    copyRow("stdio bridge", ([command] + (entry.args ?? [])).joined(separator: " "))
                }
            } else {
                Text("The server isn't running.").foregroundStyle(.secondary)
            }
            LabeledContent("Port") {
                HStack {
                    TextField("Port", text: $port).frame(width: 80).labelsHidden()
                    Button("Save") { if let p = Int(port) { app.run { _ = try await app.liveServer.setPort(p) } } }
                    Text("Applies the next time Lift starts.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder var lan: some View {
        Section("Allow access from my network") {
            Toggle("LAN access (other machines need the bearer token)", isOn: Binding(get: { app.serverStatus?.lanMode ?? false }, set: { on in
                app.gated { confirm in try await app.liveServer.setLAN(on, confirm: confirm) } then: { token = $0.token ?? token }
            }))
            .disabled(app.server == nil)
            if app.serverStatus?.lanMode == true {
                LabeledContent("Bearer token") {
                    HStack {
                        Text(showToken ? (token ?? "—") : String(repeating: "•", count: 16)).font(.system(.callout, design: .monospaced))
                        Button(showToken ? "Hide" : "Show") { showToken.toggle() }
                        Button("Copy") { copy(token ?? "") }.disabled(token == nil)
                        Button("Rotate", role: .destructive) {
                            app.gated { confirm in try await app.liveServer.rotateToken(confirm: confirm) } then: { token = $0.token }
                        }
                    }
                }
                Text("Stored in the Keychain. Rotating cuts off every remote client still using the old token.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var queue: some View {
        Section("Queue and workers") {
            let s = app.settings
            Stepper("Parallel slots: \(s.maxSlots)", value: Binding(get: { s.maxSlots }, set: { n in
                app.run { _ = try await app.engine.resourcesSet(maxSlots: n) }
            }), in: 1...16)
            LabeledContent("Memory budget (GB)") {
                TextField("GB", value: Binding(get: { s.memoryBudgetGB }, set: { gb in app.run { _ = try await app.engine.resourcesSet(memoryBudgetGB: gb) } }),
                          format: .number).frame(width: 80).labelsHidden()
            }
            LabeledContent("Unload an idle model after (minutes)") {
                TextField("Minutes", value: Binding(get: { s.idleUnloadMinutes }, set: { m in app.run { _ = try await app.engine.resourcesSet(idleUnloadMinutes: m) } }),
                          format: .number).frame(width: 80).labelsHidden()
            }
            estimates
        }
    }

    @ViewBuilder var estimates: some View {
        let rows = app.resources?.estimates ?? []
        DisclosureGroup("Learned memory estimates · \(rows.count)") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow { Text("Recipe").bold(); Text("Task").bold(); Text("Settings").bold(); Text("Load").bold(); Text("Per job").bold() }
                ForEach(rows.indices, id: \.self) { i in
                    let e = rows[i]
                    GridRow {
                        Text(e.recipe)
                        Text(e.task)
                        Text(e.keyValues).font(.system(.caption, design: .monospaced))
                        Text(e.loadBytes.map(Format.gb) ?? "—")
                        Text(e.jobBytes.map(Format.gb) ?? "—")
                    }
                }
            }
            Text("Measured peaks (max of the last 5 runs); they replace the recipe's estimate once a sample exists.").font(.caption).foregroundStyle(.secondary)
            Button("Reset learned estimates") { app.run { _ = try await app.engine.resourcesResetEstimates() } }.disabled(rows.isEmpty)
        }
    }

    @ViewBuilder var app_: some View {
        Section("App") {
            toggle("Notify when a job finishes or waits for memory", "notifications", app.settings.notifications)
            toggle("Launch at login", "launch_at_login", app.settings.launchAtLogin)
            toggle("Keep running in the menu bar (closing the window keeps the queue and server alive)", "menu_bar", app.settings.menuBar)
        }
    }

    @ViewBuilder var storage: some View {
        Section("Storage") {
            if let workdir = app.workdir {
                LabeledContent("Working directory") {
                    HStack {
                        Text(workdir.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([workdir]) }
                        Button("Move…") { choosingWorkdir = true }
                    }
                }
            }
            LabeledContent("Export folder") {
                HStack {
                    Text(app.settings.exportDir ?? "Not chosen").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    Button("Choose…") { choosingExportDir = true }
                }
            }
            .fileImporter(isPresented: $choosingExportDir, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result { app.run { _ = try await app.engine.settingsSet("export_dir", .string(url.path)) } }
            }
            LabeledContent("Export these formats by default") {
                HStack {
                    ForEach(ExportFormat.allCases, id: \.self) { f in
                        Toggle(Format.export(f), isOn: Binding(get: { app.settings.exportFormats.contains(f) }, set: { on in
                            let formats = ExportFormat.allCases.filter { $0 == f ? on : app.settings.exportFormats.contains($0) }
                            app.run { _ = try await app.engine.settingsSet("export_formats", .string(formats.map(\.rawValue).joined(separator: ","))) }
                        }))
                    }
                }
            }
            toggle("Free up space after exporting (deletes Lift's own copy once the files are safely exported)", "cleanup_after_export",
                   app.settings.cleanupAfterExport)
            if let hub = app.lift?.config.hfHub {
                LabeledContent("Weights (shared Hugging Face cache)") {
                    HStack {
                        Text(hub.path).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([hub]) }
                    }
                }
            }
        }
    }

    @ViewBuilder var accounts: some View {
        Section("Hugging Face") {
            LabeledContent("Token (only for gated weights)") {
                HStack {
                    SecureField("hf_…", text: $hfToken).labelsHidden()
                    Button("Save") {
                        let t = hfToken
                        app.run { _ = try await app.liveServer.secretsSetHFToken(t); hfToken = "" }
                    }
                    Button("Remove") { app.run { _ = try await app.liveServer.secretsSetHFToken(nil) } }
                }
            }
        }
    }

    @ViewBuilder var toolchain: some View {
        Section("Toolchain") {
            if let p = prereqs {
                LabeledContent("Homebrew (native)", value: p.tools.brew ?? "missing")
                if let rosetta = p.tools.rosettaBrew { LabeledContent("Intel Homebrew (not used)", value: rosetta) }
                LabeledContent("git", value: p.tools.git ?? "missing")
                LabeledContent("uv", value: p.tools.uv ?? "missing")
                if let metal = p.metalToolchain { LabeledContent("Metal Toolchain (needed by some models)", value: metal ? "installed" : "missing") }
                if p.tools.brew == nil || p.tools.git == nil || p.tools.uv == nil || p.metalToolchain == false {
                    Button("Install Missing Tools…") { installTools() }
                }
            }
            if !toolLog.isEmpty {
                ScrollView {
                    Text(toolLog.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
        }
    }

    func installTools() {
        toolLog = []
        let onLine: @Sendable (String) -> Void = { line in Task { @MainActor in toolLog.append(line) } }
        let metal = app.needsMetalToolchain
        app.gated { confirm in try await app.engine.systemInstallPrereqs(metal: metal, confirm: confirm, onLine: onLine) } then: { prereqs = $0 }
    }
}
