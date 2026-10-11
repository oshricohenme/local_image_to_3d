import AppKit
import LiftCore
import SwiftUI

/// History (mockup History.dc.html): finished jobs with filters, and the selected job's viewer,
/// outputs, options used and actions (Reveal, Copy path, Use as input for…, Retry, Retry with changes,
/// Copy as curl, Delete).
struct HistoryView: View {
    let app: AppModel
    @State private var model = HistoryModel()
    @State private var retrying: JobView?

    var body: some View {
        HSplitView {
            VStack(spacing: 8) {
                Picker("Filter", selection: $model.filter) {
                    ForEach(HistoryFilter.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                List(model.jobs, id: \.job.id, selection: $model.selected) { v in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(v.job.title).bold()
                        Text("\(badge(v)) · \(chain(v)) · via \(Format.source(v.job.source))").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(v.job.id)
                }
                .overlay {
                    if model.jobs.isEmpty { ContentUnavailableView("No finished jobs", systemImage: "tray") }
                }
            }
            .padding(.top, 8)
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            detail.frame(minWidth: 420, maxWidth: .infinity)
        }
        .searchable(text: $model.text, prompt: "Title")
        .navigationTitle("History")
        .task(id: "\(model.filter)|\(model.text)") {
            while !Task.isCancelled {
                if let lift = app.lift { try? await model.reload(lift, models: app.models) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .sheet(item: Binding(get: { retrying.map(RetryTarget.init) }, set: { if $0 == nil { retrying = nil } })) { target in
            RetrySheet(app: app, job: target.job) { retrying = nil }
        }
    }

    func badge(_ v: JobView) -> String {
        if v.job.state != .succeeded { return Format.state(v.job.state) }
        return HistoryModel.output(of: v, models: app.models).map { Format.io($0, asOutput: true) } ?? "Done"
    }

    func chain(_ v: JobView) -> String {
        v.steps.map { s in app.models.first { $0.id == s.recipe }?.name ?? s.recipe }.joined(separator: " → ")
    }

    @ViewBuilder var detail: some View {
        if let v = model.current {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(v.job.title).font(.title2).bold()
                    Text("\(chain(v)) · via \(Format.source(v.job.source)) · \(v.job.createdAt.formatted())").foregroundStyle(.secondary)
                    if v.job.state == .succeeded, let first = v.outputs.first {
                        ResultViewer(path: first).frame(height: 360).clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        failure(v)
                    }
                    outputs(v)
                    used(v)
                    actions(v)
                }
                .padding()
            }
        } else {
            ContentUnavailableView("Select a job", systemImage: "square.grid.2x2")
        }
    }

    func failure(_ v: JobView) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(v.job.state == .cancelled ? "Cancelled" : "Failed at step \(v.job.currentStep + 1)").font(.headline)
            if let error = v.job.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            Text(app.logTail(v.job.id, maxBytes: 4_096)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(8).background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder func outputs(_ v: JobView) -> some View {
        if !v.outputs.isEmpty {
            Text("Outputs").font(.headline)
            ForEach(v.outputs, id: \.self) { path in
                HStack {
                    Text(URL(filePath: path).lastPathComponent).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                    Button("Copy path") { copy(path) }
                    useAsInput(path, from: v)
                }
            }
        }
    }

    /// Lists every task whose first input accepts this output's type, so chains work across modalities.
    func useAsInput(_ path: String, from v: JobView) -> some View {
        let type = HistoryModel.output(of: v, models: app.models)
        let refs = app.models.filter { !$0.isUnsupported }.flatMap { m in
            m.recipe.tasks.filter { t in type.map { t.inputs.first?.type.accepts($0) == true } ?? false }.map { (m, $0) }
        }
        return Menu("Use as input for…") {
            ForEach(refs, id: \.1.id) { m, t in
                Button("\(m.name) · \(t.label)") {
                    app.generate.use(path, for: TaskRef(recipe: m.id, task: t.id))
                    app.section = .generate
                }
            }
        }
        .disabled(refs.isEmpty)
        .fixedSize()
    }

    func used(_ v: JobView) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Options used").font(.headline)
            ForEach(v.steps, id: \.idx) { s in
                Text("\(app.models.first { $0.id == s.recipe }?.name ?? s.recipe) · \(s.task)").bold()
                ForEach(s.settings.keys.sorted(), id: \.self) { key in
                    HStack { Text(key).foregroundStyle(.secondary); Spacer(); Text(s.settings[key]!.description) }.font(.callout)
                }
            }
        }
    }

    func actions(_ v: JobView) -> some View {
        HStack {
            Button("Retry") { app.run { try await app.retry(v.job.id) } }
            Button("Retry with changes…") { retrying = v }
            Button("Copy as curl") { copy(HistoryModel.curl(v, apiBase: app.serverStatus?.urls.api ?? "http://127.0.0.1:7777/v1", models: app.models)) }
                .disabled(app.serverStatus == nil)
            Spacer()
            Button("Delete…", role: .destructive) {
                app.gated { confirm in try await app.engine.jobsDelete(v.job.id, confirm: confirm) }
            }
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct RetryTarget: Identifiable {
    let job: JobView
    var id: String { job.job.id }
}

/// Retry with new settings for the step a retry restarts from (spec §10 `jobs_retry`).
struct RetrySheet: View {
    let app: AppModel
    let job: JobView
    let done: () -> Void
    @State private var values: [String: SettingValue] = [:]
    @State private var errors: [FieldError] = []

    var step: StepRecord { job.steps.first { $0.state != .succeeded } ?? job.steps[0] }

    var body: some View {
        let task = app.models.first { $0.id == step.recipe }?.recipe.task(step.task)
        Form {
            Section("Retry \(job.job.title) from step \(step.idx + 1)") {
                SettingsForm(defs: task?.settings ?? [], values: $values) { key in
                    errors.filter { $0.field == "settings.\(key)" }.map(\.message)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { values = step.settings }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: done) }
            ToolbarItem(placement: .confirmationAction) {
                Button("Retry") {
                    Task {
                        do {
                            try await app.retry(job.job.id, settings: values)
                            done()
                        } catch LiftError.invalidInput(let e) {
                            errors = e
                        } catch {
                            app.alert = Format.error(error)
                        }
                    }
                }
            }
        }
    }
}
