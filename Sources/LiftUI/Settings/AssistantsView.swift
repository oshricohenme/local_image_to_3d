import AppKit
import SwiftUI

/// One row per AI assistant: what it is, where it stands, and one button (Connect, Disconnect, Update or Replace).
/// Settings lists all three with the do-it-yourself command under Show details; setup lists only those on this Mac.
struct AssistantRows: View {
    let app: AppModel
    var installedOnly = false

    var body: some View {
        let rows = app.assistants.rows
        let shown = Assistant.allCases.filter { !installedOnly || rows[$0]?.state.map { $0 != .notInstalled } ?? false }
        if installedOnly && rows.count == Assistant.allCases.count && shown.isEmpty {
            Text("No AI assistants found on this Mac. You can connect one later in Settings.").foregroundStyle(.secondary)
        }
        ForEach(shown) { a in
            AssistantRow(app: app, assistant: a, row: rows[a] ?? .init(), manual: !installedOnly)
        }
    }
}

struct AssistantRow: View {
    let app: AppModel
    let assistant: Assistant
    let row: AssistantsModel.Row
    let manual: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(assistant.name).bold()
                    Text(assistant.blurb).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                status
                if row.busy { ProgressView().controlSize(.small) } else { button }
            }
            if let note = row.note { Label(note, systemImage: "info.circle").font(.callout) }
            if let failure = row.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            if let details = row.details {
                LocalDisclosure("Show details") {
                    Text(details).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if manual, let connector = app.assistants.connector {
                LocalDisclosure("Show details: do it yourself") {
                    let text = connector.snippet(assistant)
                    HStack(alignment: .top) {
                        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        .accessibilityLabel("Copy the \(assistant.name) setup")
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var status: some View {
        switch row.state {
        case nil: Text("Checking…").foregroundStyle(.secondary)
        case .connected: Text("Connected ✓").foregroundStyle(.green)
        case .notConnected: Text("Not connected").foregroundStyle(.secondary)
        case .needsUpdate: Text("Needs updating").foregroundStyle(.orange)
        case .taken: Text("Another “lift” is set up").foregroundStyle(.secondary)
        case .notInstalled:
            HStack(spacing: 4) {
                Text("Not installed —").foregroundStyle(.secondary)
                Link("Get \(assistant.name) ↗", destination: assistant.download)
            }
        }
    }

    @ViewBuilder var button: some View {
        let model = app.assistants
        switch row.state {
        case .notConnected: Button("Connect") { Task { await model.connect(assistant) } }
        case .connected: Button("Disconnect") { Task { await model.disconnect(assistant) } }
        case .needsUpdate: Button("Update") { Task { await model.connect(assistant) } }
        case .taken:
            Button("Replace…") {
                app.confirmation = Confirmation(message: "\(assistant.name) already has a different tool called “lift”. Replace it with Lift?",
                                                action: "Replace") { await model.connect(assistant, replacing: true) }
            }
        case .notInstalled, nil: EmptyView()
        }
    }
}
