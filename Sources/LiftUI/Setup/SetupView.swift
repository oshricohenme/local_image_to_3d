import AppKit
import LiftCore
import SwiftUI

/// The first-launch wizard: where Lift keeps its files → helper tools → models → Hugging Face (optional) →
/// connecting an AI assistant. Plain language first; logs and commands sit under Details (spec §1).
struct SetupView: View {
    let app: AppModel
    @State private var model: SetupModel
    @State private var choosing = false

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: SetupModel(app: app))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up Lift").font(.largeTitle).bold()
            HStack {
                ForEach(SetupModel.Step.allCases, id: \.self) { s in
                    Text("\(s.rawValue + 1) · \(s.title)").font(.caption).bold(s == model.step)
                        .foregroundStyle(s.rawValue <= model.step.rawValue ? .primary : .secondary)
                }
            }
            Divider()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button(model.step == .mcp ? "Finish" : "Continue") { Task { await model.next(app) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy)
            }
        }
        .padding(32)
        .frame(minWidth: 680, minHeight: 480)
        .task { await model.load(app) }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.workdir = url }
        }
    }

    @ViewBuilder var content: some View {
        switch model.step {
        case .folders:
            Text("Lift keeps the models you install, your results and its own records in one folder. You can move it later in Settings.")
            LabeledContent("Folder") {
                HStack {
                    Text(model.workdir.path).font(.system(.body, design: .monospaced))
                    Button("Choose…") { choosing = true }
                }
            }
        case .toolchain:
            Text("Lift uses three free helper tools to download and set up models: Homebrew, git and uv.")
            if let p = model.prereqs {
                tool("Homebrew", p.tools.brew)
                tool("git", p.tools.git)
                tool("uv", p.tools.uv)
                if let rosetta = p.tools.rosettaBrew {
                    Text("An older Intel copy of Homebrew is at \(rosetta). Lift leaves it as it is and installs its own.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.missingTools {
                Text("When you press Install, macOS asks for your password once, to let Homebrew create its folder. Lift never sees your password.")
                    .font(.callout)
                Button("Install") { model.installTools(app) }.buttonStyle(.borderedProminent)
            }
            Button("Check Again") { Task { await model.checkTools(app) } }
            if !model.log.isEmpty {
                DisclosureGroup("Details") {
                    ScrollView {
                        Text(model.log.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 160)
                }
            }
        case .recipes:
            Text("These models come with Lift. Nothing is downloaded now: each one installs when you first use it.")
            ForEach(model.recipes.filter { $0.state == .available }, id: \.id) { r in
                Label(r.name ?? r.id, systemImage: "shippingbox")
            }
            if !model.keptLocal.isEmpty {
                Text("Your edited copies were kept: \(model.keptLocal.joined(separator: ", "))").font(.caption)
            }
        case .huggingFace:
            Text("Some models' authors ask you to accept their terms on Hugging Face before downloading. You only need this for those models, and you can do it later in Settings.")
            VStack(alignment: .leading, spacing: 6) {
                Link("1. Create a free Hugging Face account", destination: URL(string: "https://huggingface.co/join")!)
                Text("2. Open each of these pages and accept the terms:")
                ForEach(model.gatedRepos(app), id: \.self) { repo in
                    Link("    \(repo)", destination: URL(string: "https://huggingface.co/\(repo)")!)
                }
                Link("3. Create an access token (Read is enough)", destination: URL(string: "https://huggingface.co/settings/tokens")!)
                Text("4. Paste it here. Lift keeps it in your Mac's Keychain.")
            }
            SecureField("hf_…", text: $model.hfToken).frame(maxWidth: 360)
        case .mcp:
            if let s = app.serverStatus {
                Text("AI assistants such as Claude Code can use Lift too. To connect Claude Code, run this once in Terminal:")
                snippet("claude mcp add --transport http lift \(s.urls.mcp)")
                if let entry = s.mcpConfig["mcpServers"]?["lift"], let command = entry.command {
                    DisclosureGroup("Details: other assistants") {
                        Text("Assistants that start a program instead of using a web address can run:")
                        snippet(([command] + (entry.args ?? [])).joined(separator: " "))
                    }
                }
            } else {
                Text("Lift's assistant connection didn't start. Settings shows why, and the command once it's running.")
            }
        }
    }

    func tool(_ name: String, _ path: String?) -> some View {
        Label(path == nil ? "\(name): not installed yet" : "\(name): ready", systemImage: path == nil ? "circle" : "checkmark.circle.fill")
    }

    func snippet(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}
