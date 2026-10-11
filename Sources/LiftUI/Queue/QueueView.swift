import LiftCore
import SwiftUI

/// Queue (mockup Queue.dc.html + spec §12): slot and memory meters, workers with their footprint,
/// running jobs with stage and live log, and waiting jobs with their reason, priority, force start,
/// cancel and drag to reorder. Order is LiftCore's (priority, position, submission); nothing here reorders on its own.
struct QueueView: View {
    let app: AppModel

    var body: some View {
        let jobs = app.queue?.jobs ?? []
        let running = jobs.filter { $0.job.state.isActive }
        let waiting = jobs.filter { !$0.job.state.isActive }
        List {
            Section { meters }
            if let workers = app.resources?.workers, !workers.isEmpty {
                Section("Workers") { ForEach(workers, id: \.id) { workerRow($0) } }
            }
            Section("Running · \(running.count)") {
                ForEach(running, id: \.job.id) { runningRow($0) }
            }
            Section("Waiting · \(waiting.count)") {
                if waiting.isEmpty {
                    Text("Nothing waiting. Drop files on Generate, or POST /v1/jobs.").foregroundStyle(.secondary)
                }
                ForEach(waiting, id: \.job.id) { waitingRow($0) }
                    .onMove { from, to in move(waiting, from: from, to: to) }
            }
        }
        .navigationTitle("Queue")
        .toolbar {
            if !app.interrupted.isEmpty {
                Button("Interrupted · \(app.interrupted.count)") { app.showInterrupted = true }
            }
            Button(app.queue?.paused == true ? "Resume Queue" : "Pause Queue") {
                app.run { _ = app.queue?.paused == true ? try await app.engine.queueResume() : try await app.engine.queuePause() }
            }
        }
    }

    // MARK: rows

    @ViewBuilder var meters: some View {
        if let r = app.resources {
            let running = app.queue?.running ?? 0
            Gauge(value: Double(running), in: 0...Double(max(r.maxSlots, 1))) {
                Text("Slots")
            } currentValueLabel: {
                Text("\(running) of \(r.maxSlots) running")
            }
            Gauge(value: Double(min(r.reservedBytes, r.budgetBytes)), in: 0...Double(max(r.budgetBytes, 1))) {
                Text("Memory budget")
            } currentValueLabel: {
                Text("\(Format.gb(r.reservedBytes)) reserved of \(Format.gb(r.budgetBytes)) · \(Format.gb(r.systemFreeBytes)) free on this Mac")
            }
        }
    }

    func workerRow(_ w: WorkerView) -> some View {
        HStack {
            Image(systemName: "cpu")
            VStack(alignment: .leading) {
                Text("\(app.models.first { $0.id == w.recipe }?.name ?? w.recipe) · \(w.ready ? "loaded" : "loading")").bold()
                Text("\(Format.gb(w.footprintBytes)) in use · \(Format.gb(w.reservedBytes)) reserved · \(w.job == nil ? "idle" : "running a job")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Unload") { app.gated { confirm in try await app.engine.workersUnload(w.id, confirm: confirm) } }
        }
    }

    func runningRow(_ v: JobView) -> some View {
        let step = v.steps[min(v.job.currentStep, v.steps.count - 1)]
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(v.job.title).font(.headline)
                Text(Format.state(v.job.state)).font(.caption).padding(.horizontal, 6).background(.blue.opacity(0.15), in: Capsule())
                Text("via \(Format.source(v.job.source))").font(.caption).foregroundStyle(.secondary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.elapsed(since: step.startedAt, now: context.date)).monospacedDigit()
                }
                // Stop is immediate (LiftCore kills that job's worker), after LiftCore's own confirmation text.
                Button("Stop", systemImage: "stop.fill", role: .destructive) {
                    app.gated { confirm in try await app.engine.jobsCancel(v.job.id, confirm: confirm) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            Text(stepLine(v)).font(.caption).foregroundStyle(.secondary)
            CreditLinks(job: v)
            ProgressView(value: step.fraction ?? 0) { Text(step.stage ?? "Starting…").font(.caption) }
            LocalDisclosure("Live log") {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    ScrollView {
                        Text(app.logTail(v.job.id)).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 160)
                }
            }
        }
        .padding(.vertical, 4)
    }

    func waitingRow(_ v: JobView) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(v.job.title).bold()
                Text(stepLine(v)).font(.caption).foregroundStyle(.secondary)
            }
            Text("via \(Format.source(v.job.source))").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v.job.state == .interrupted ? "Interrupted" : Format.waitReason(v.job.waitReason)).font(.caption)
            Picker("Priority", selection: Binding(get: { v.job.priority }, set: { p in app.run { _ = try await app.engine.jobsSetPriority(v.job.id, p) } })) {
                ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .labelsHidden()
            .frame(width: 90)
            if case .memory = v.job.waitReason {
                Button("Start Now Anyway") { app.gated { confirm in try await app.engine.jobsForceStart(v.job.id, confirm: confirm) } }
            }
            Button("Cancel", systemImage: "xmark") { app.gated { confirm in try await app.engine.jobsCancel(v.job.id, confirm: confirm) } }
                .labelStyle(.iconOnly)
        }
    }

    func stepLine(_ v: JobView) -> String {
        let chain = v.steps.map { s in app.models.first { $0.id == s.recipe }?.name ?? s.recipe }.joined(separator: " → ")
        return "Step \(v.job.currentStep + 1) of \(v.steps.count) · \(chain) · \(v.job.priority.rawValue) priority"
    }

    /// A drag sets the job's manual position (spec §7) next to its new neighbour.
    func move(_ waiting: [JobView], from: IndexSet, to: Int) {
        guard let i = from.first, let target = QueueOrder.target(waiting.map(\.job.id), from: i, to: to) else { return }
        let id = waiting[i].job.id
        app.run { _ = try await app.engine.jobsMove(id, to: target) }
    }
}

/// Turns a list drag (`onMove` indices) into a `jobs_move` target; nil when the job stays put.
enum QueueOrder {
    static func target(_ ids: [String], from: Int, to: Int) -> MoveTarget? {
        guard ids.indices.contains(from), to != from, to != from + 1 else { return nil }
        return to < ids.count ? .before(ids[to]) : .after(ids[ids.count - 1])
    }
}
