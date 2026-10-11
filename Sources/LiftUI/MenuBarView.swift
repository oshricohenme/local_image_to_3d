import AppKit
import LiftCore
import SwiftUI

/// The menu bar extra (mockup MenuBar.dc.html): server, the running job, up next, the last finished
/// job, and Open / Pause / Unload / Quit.
public struct MenuBarView: View {
    let app: AppModel
    let openWindow: () -> Void

    public init(app: AppModel, openWindow: @escaping () -> Void) {
        self.app = app
        self.openWindow = openWindow
    }

    public var body: some View {
        let jobs = app.queue?.jobs ?? []
        let running = jobs.filter { $0.job.state.isActive }
        let waiting = jobs.filter { !$0.job.state.isActive }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lift").bold()
                Spacer()
                Text(app.serverStatus.map { "\($0.bind):\($0.port)" } ?? "server stopped").font(.caption.monospaced())
            }
            ForEach(running, id: \.job.id) { v in
                let step = v.steps[min(v.job.currentStep, v.steps.count - 1)]
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.job.title).bold()
                    Text("\(step.recipe) · \(step.stage ?? Format.state(v.job.state))").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: step.fraction ?? 0)
                }
            }
            if !waiting.isEmpty {
                Text("Up next · \(waiting.count)").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(waiting.prefix(3), id: \.job.id) { v in
                    HStack {
                        Text(v.job.title)
                        Spacer()
                        Text(Format.waitReason(v.job.waitReason)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let last = app.lastFinished, let path = HistoryModel.viewable(last) {
                Text("Just finished").font(.caption.bold()).foregroundStyle(.secondary)
                HStack {
                    Text(last.job.title)
                    Spacer()
                    Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                }
            }
            Divider()
            Button("Open Lift", action: openWindow)
            Button(app.queue?.paused == true ? "Resume Queue" : "Pause Queue") {
                app.run { _ = app.queue?.paused == true ? try await app.engine.queueResume() : try await app.engine.queuePause() }
            }
            ForEach(app.resources?.workers ?? [], id: \.id) { w in
                Button("Unload \(app.models.first { $0.id == w.recipe }?.name ?? w.recipe)") {
                    app.gated { confirm in try await app.engine.workersUnload(w.id, confirm: confirm) }
                }
            }
            Button("Quit Lift (stops the server)") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .padding(12)
        .frame(width: 320)
    }
}
