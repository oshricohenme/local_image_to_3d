import AppKit
import LiftServer
import SwiftUI

/// Settings → Show Log: every request AI assistants (MCP) and scripts (HTTP API) sent to Lift, newest first,
/// with what they sent and what Lift answered. For troubleshooting; secrets are already redacted.
public struct RequestLogView: View {
    let app: AppModel
    @State private var entries: [RequestLogEntry] = []
    @State private var version = -1
    @State private var selection: RequestLogEntry.ID?
    @State private var search = ""
    @State private var filter = Filter.all

    enum Filter: String, CaseIterable { case all = "All", mcp = "MCP", http = "HTTP API", failed = "Failed" }

    public init(app: AppModel) { self.app = app }

    var shown: [RequestLogEntry] {
        entries.filter { e in
            switch filter {
            case .all: true
            case .mcp: e.kind == .mcp
            case .http: e.kind == .http
            case .failed: e.failed
            }
        }.filter { e in
            search.isEmpty || [e.summary, e.path, e.client ?? "", e.request ?? "", e.response ?? ""].contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    public var body: some View {
        HSplitView {
            List(shown, selection: $selection) { row($0) }
                .frame(minWidth: 380)
                .overlay {
                    if shown.isEmpty {
                        ContentUnavailableView(entries.isEmpty ? "No requests yet" : "No matches", systemImage: "list.bullet.rectangle",
                                               description: Text(entries.isEmpty ? "Requests from AI assistants and scripts appear here as they arrive." : ""))
                    }
                }
            Group {
                if let e = entries.first(where: { $0.id == selection }) { detail(e) } else {
                    ContentUnavailableView("Select a request", systemImage: "arrow.left")
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $search, prompt: "Search requests and answers")
        .toolbar {
            Picker("Show", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) } }.pickerStyle(.segmented)
            Button("Show in Finder", systemImage: "folder") {
                if let file = app.server?.requestLog.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            Button("Clear", systemImage: "trash") { Task { await app.server?.requestLog.clear() } }
        }
        .navigationTitle("MCP & API Log")
        .task(id: app.server.map(ObjectIdentifier.init)) {
            version = -1
            while !Task.isCancelled {
                if let log = app.server?.requestLog, let s = await log.snapshot(newerThan: version) { (version, entries) = s }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func row(_ e: RequestLogEntry) -> some View {
        HStack(spacing: 8) {
            Circle().fill(e.failed ? Color.red : Color.green).frame(width: 7, height: 7)
            Text(e.time, format: .dateTime.hour().minute().second()).monospacedDigit().foregroundStyle(.secondary)
            Text(e.kind == .mcp ? "MCP" : "API").font(.caption2.bold()).padding(.horizontal, 4)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            Text(e.summary).lineLimit(1)
            Spacer()
            Text("\(e.milliseconds) ms").monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    func detail(_ e: RequestLogEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(e.summary).font(.title3.bold()).textSelection(.enabled)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    fact("Time", e.time.formatted(date: .abbreviated, time: .standard))
                    fact("Status", "\(e.status)\(e.failed ? " · failed" : "") · \(e.milliseconds) ms")
                    fact("Request", "\(e.method) \(e.path)")
                    if let c = e.client { fact("Client", c) }
                    if let s = e.session { fact("Session", s) }
                    if let f = e.from { fact("From", f) }
                }
                body("Sent", e.request)
                body("Answer", e.response)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder func body(_ title: String, _ text: String?) -> some View {
        let text = text.map(Self.pretty)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let text {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                }
            }
            Text(text ?? "(nothing)").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                .foregroundStyle(text == nil ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// Each line that is JSON, indented; anything else as is.
    static func pretty(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                  let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            else { return String(line) }
            return String(decoding: data, as: UTF8.self)
        }.joined(separator: "\n")
    }
}
