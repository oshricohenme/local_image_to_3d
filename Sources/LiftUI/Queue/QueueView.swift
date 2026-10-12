import AppKit
import LiftCore
import QuickLookThumbnailing
import SwiftUI

enum QueueFilter: Hashable, CaseIterable {
    case all, running, waiting, failed

    var label: String {
        switch self {
        case .all: "All"
        case .running: "Running"
        case .waiting: "Up next"
        case .failed: "Failed"
        }
    }
}

/// Queue (mockup "Lift Queue Redesign" + spec §12): slot, memory and loaded-model cards; running jobs with
/// their photos, steps, stage, live log and credits; waiting jobs with their reason, priority, force start,
/// cancel and drag to reorder; failed jobs to retry or delete. Order is LiftCore's (priority, position,
/// submission); nothing here reorders on its own.
struct QueueView: View {
    let app: AppModel
    @State private var filter = QueueFilter.all
    @State private var openLogs: Set<String> = []
    @State private var openCredits: Set<String> = []

    var body: some View {
        let jobs = app.queue?.jobs ?? []
        let running = jobs.filter { $0.job.state.isActive }
        let waiting = jobs.filter { !$0.job.state.isActive }
        let failed = app.failed
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                capacity(running: running.count, waiting: waiting.count)
                if running.isEmpty && waiting.isEmpty && failed.isEmpty {
                    empty
                } else {
                    filters(running: running.count, waiting: waiting.count, failed: failed.count)
                    if show(.running, running) { runningSection(running) }
                    if show(.waiting, waiting) { waitingSection(waiting) }
                    if show(.failed, failed) { failedSection(failed) }
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Queue")
        .toolbar {
            let paused = app.queue?.paused == true
            Button {
                app.run { _ = paused ? try await app.engine.queueResume() : try await app.engine.queuePause() }
            } label: {
                Label(paused ? "Resume Queue" : "Pause Queue", systemImage: paused ? "play.fill" : "pause.fill").labelStyle(.titleAndIcon)
            }
        }
    }

    /// "All" shows the sections that have jobs; a single filter always shows its own, empty or not.
    func show(_ f: QueueFilter, _ jobs: [JobView]) -> Bool {
        filter == f || (filter == .all && !jobs.isEmpty)
    }

    // MARK: capacity

    func capacity(running: Int, waiting: Int) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
            if let r = app.resources {
                stat("Slots", note: "\(running) of \(r.maxSlots) busy", value: "\(running)",
                     unit: waiting > 0 ? "running · \(waiting) waiting" : "running") {
                    HStack(spacing: 4) {
                        ForEach(0..<max(r.maxSlots, 1), id: \.self) { i in
                            Capsule().fill(i < running ? Color.accentColor : Color.primary.opacity(0.08)).frame(height: 6)
                        }
                    }
                }
                stat("Memory for models", note: "\(Format.gb(r.systemFreeBytes)) free on this Mac",
                     value: Self.number(r.reservedBytes), unit: "of \(Format.gb(r.budgetBytes)) reserved") {
                    Meter(fraction: Double(r.reservedBytes) / Double(max(r.budgetBytes, 1)))
                }
                loadedModels(r.workers)
            }
        }
    }

    /// 13.3 (GB), 0 when nothing is reserved.
    static func number(_ bytes: Int) -> String {
        bytes == 0 ? "0" : (Double(bytes) / 1_000_000_000).formatted(.number.precision(.fractionLength(1)))
    }

    func stat(_ title: String, note: String, value: String, unit: String, @ViewBuilder bar: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(note)
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
            bar()
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(12)
    }

    func loadedModels(_ workers: [WorkerView]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Loaded models").font(.caption).foregroundStyle(.secondary)
            if workers.isEmpty {
                Text("None. A model loads when a job needs it.").foregroundStyle(.secondary)
            }
            ForEach(workers, id: \.id) { w in
                HStack(spacing: 10) {
                    Image(systemName: "cpu")
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 32, height: 32)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(modelName(w.recipe)).fontWeight(.semibold)
                        Text("\(Format.gb(w.footprintBytes)) · \(workerState(w))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button("Unload") { app.gated { confirm in try await app.engine.workersUnload(w.id, confirm: confirm) } }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(12)
    }

    func workerState(_ w: WorkerView) -> String {
        guard w.ready else { return "loading" }
        guard let id = w.job else { return "idle" }
        return "busy with " + (app.queue?.jobs.first { $0.job.id == id }?.job.title ?? "a job")
    }

    // MARK: filters

    func filters(running: Int, waiting: Int, failed: Int) -> some View {
        let counts: [QueueFilter: Int] = [.all: running + waiting + failed, .running: running, .waiting: waiting, .failed: failed]
        return HStack(spacing: 2) {
            ForEach(QueueFilter.allCases, id: \.self) { f in
                let on = filter == f
                Button { filter = f } label: {
                    HStack(spacing: 6) {
                        Text(f.label).fontWeight(on ? .semibold : .regular)
                        Text("\(counts[f] ?? 0)")
                            .font(.caption2.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .foregroundStyle(f == .failed ? Color.red : .secondary)
                            .background(f == .failed ? Color.red.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule())
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(on ? Color.primary.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .card(9)
    }

    func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }

    func none(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(.vertical, 4)
    }

    // MARK: running

    func runningSection(_ running: [JobView]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Running")
            if running.isEmpty { none("Nothing is running.") }
            ForEach(running, id: \.job.id) { runningCard($0) }
        }
    }

    func runningCard(_ v: JobView) -> some View {
        let step = v.steps[min(v.job.currentStep, v.steps.count - 1)]
        let id = v.job.id
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 18) {
                PhotoGrid(paths: JobPhotos.paths(v))
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text(v.job.title).font(.system(size: 16, weight: .semibold)).lineLimit(1)
                        priorityTag(v.job.priority)
                        Text(source(v.job.source)).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Format.elapsed(since: step.startedAt, now: context.date)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        // Stop is immediate (LiftCore kills that job's worker), after LiftCore's own confirmation text.
                        Button(role: .destructive) {
                            app.gated { confirm in try await app.engine.jobsCancel(id, confirm: confirm) }
                        } label: {
                            Label("Stop", systemImage: "stop.fill").labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                    steps(v)
                    VStack(alignment: .leading, spacing: 7) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(Format.stage(step.stage, fraction: step.fraction)).lineLimit(1)
                            Spacer()
                            let task = app.models.first { $0.id == step.recipe }?.recipe.tasks.first { $0.id == step.task }
                            if let position = Format.position(step: v.job.currentStep, of: v.steps.count,
                                                              phase: task?.phase(of: step.stage, settings: step.settings)) {
                                Text(position).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        // A finished bar while the step still runs is a step without a bar (decoding, baking): keep moving.
                        if let f = step.fraction, f < 1 { Meter(fraction: f) } else { ProgressView().progressViewStyle(.linear) }
                        // What the model is doing right now, live: the newest line of its log.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(Format.lastLine(app.logTail(id, maxBytes: 4_096)))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            Divider()
            HStack(spacing: 4) {
                footerButton(openLogs.contains(id) ? "Hide log" : "Show log", symbol: "terminal") { openLogs.formSymmetricDifference([id]) }
                if !v.job.credits.isEmpty {
                    footerButton("Made with " + v.job.credits.map(\.project).formatted(), symbol: "info.circle") { openCredits.formSymmetricDifference([id]) }
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            if openCredits.contains(id) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(v.job.credits, id: \.project) { a in
                        Link(Credits.madeWith(a), destination: a.homepage).font(.caption)
                    }
                }
                .padding(.horizontal, 22).padding(.bottom, 16)
            }
            if openLogs.contains(id) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in log(id) }
            }
        }
        .card(14)
    }

    /// One chip per step: done ones ticked, the current one highlighted, the rest outlined.
    func steps(_ v: JobView) -> some View {
        HStack(spacing: 8) {
            ForEach(v.steps, id: \.idx) { s in
                if s.idx > 0 {
                    Image(systemName: "arrow.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                let current = s.idx == v.job.currentStep
                let done = s.idx < v.job.currentStep
                HStack(spacing: 8) {
                    ZStack {
                        if current {
                            Circle().fill(Color.accentColor)
                        } else {
                            Circle().strokeBorder(Color.secondary.opacity(0.6))
                        }
                        if done {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        } else {
                            Text("\(s.idx + 1)").font(.system(size: 11, weight: .bold)).foregroundStyle(current ? .white : .secondary)
                        }
                    }
                    .frame(width: 20, height: 20)
                    Text(modelName(s.recipe)).fontWeight(.semibold).foregroundStyle(current ? .primary : .secondary)
                    if let label = app.models.first(where: { $0.id == s.recipe })?.recipe.task(s.task)?.label {
                        Text(label).foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 6)
                .background(current ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(current ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.1)))
            }
        }
    }

    func footerButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    func log(_ id: String) -> some View {
        ScrollView {
            Text(app.logTail(id))
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .frame(height: 160)
        .background(Color.black.opacity(0.25))
    }

    // MARK: waiting

    func waitingSection(_ waiting: [JobView]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Up next · \(waiting.count)")
                Spacer()
                if waiting.count > 1 { Text("Drag to reorder").font(.caption).foregroundStyle(.secondary) }
            }
            if waiting.isEmpty {
                none("Nothing waiting.")
            } else {
                rows(waiting) { i, v in waitingRow(v, position: i + 1) }
                    .card(14)
            }
        }
    }

    func waitingRow(_ v: JobView, position: Int) -> some View {
        let id = v.job.id
        let memory: Bool = if case .memory = v.job.waitReason { true } else { false }
        return HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).help("Drag to reorder")
            Text("\(position)").font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(width: 18, alignment: .trailing)
            Thumbnail(path: JobPhotos.paths(v).first, size: 48)
            VStack(alignment: .leading, spacing: 1) {
                Text(v.job.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Text("\(chain(v)) · \(source(v.job.source))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Circle().frame(width: 6, height: 6)
                Text(Format.waitReason(v.job.waitReason))
            }
            .font(.caption)
            .foregroundStyle(memory ? Color.orange : .secondary)
            if memory {
                Button("Start Anyway") { app.gated { confirm in try await app.engine.jobsForceStart(id, confirm: confirm) } }
                    .controlSize(.small)
            }
            HStack(spacing: 6) {
                Text("Priority").font(.caption).foregroundStyle(.secondary)
                Picker("Priority", selection: Binding(get: { v.job.priority }, set: { p in app.run { _ = try await app.engine.jobsSetPriority(id, p) } })) {
                    ForEach(Priority.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            iconButton("xmark", label: "Cancel \(v.job.title)") {
                app.gated { confirm in try await app.engine.jobsCancel(id, confirm: confirm) }
            }
        }
        .draggable(id)
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first else { return false }
            move(dragged, onto: id)
            return true
        }
    }

    /// A row dropped on another takes that row's place: before it when moving up, after it when moving down.
    func move(_ dragged: String, onto target: String) {
        let ids = (app.queue?.jobs ?? []).filter { !$0.job.state.isActive }.map(\.job.id)
        guard let from = ids.firstIndex(of: dragged), let onto = ids.firstIndex(of: target),
              let to = QueueOrder.target(ids, from: from, to: from < onto ? onto + 1 : onto) else { return }
        app.run { _ = try await app.engine.jobsMove(dragged, to: to) }
    }

    // MARK: failed

    func failedSection(_ failed: [JobView]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionTitle("Failed · \(failed.count)")
                Spacer()
                if failed.count > 1 {
                    Button {
                        let ids = failed.filter { !$0.job.cleanedUp && !$0.job.exportPending }.map(\.job.id)
                        app.run { try await app.retryAll(ids) }
                    } label: {
                        Label("Retry All", systemImage: "arrow.trianglehead.2.clockwise").labelStyle(.titleAndIcon)
                    }
                    .controlSize(.small)
                }
            }
            if failed.isEmpty {
                none("No failed jobs.")
            } else {
                rows(failed) { _, v in failedRow(v) }
                    .card(14, stroke: Color.red.opacity(0.25))
            }
        }
    }

    func failedRow(_ v: JobView) -> some View {
        let id = v.job.id
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Thumbnail(path: JobPhotos.paths(v).first, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(v.job.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                        Tag(text: "Failed", color: .red)
                    }
                    HStack(spacing: 0) {
                        Text("\(chain(v)) · \(source(v.job.source)) · ")
                        Text(v.job.finishedAt ?? v.job.updatedAt, format: .relative(presentation: .named))
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Text(v.job.error ?? "Failed at step \(v.job.currentStep + 1).")
                        .font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(openLogs.contains(id) ? "Hide Log" : "Show Log") { openLogs.formSymmetricDifference([id]) }
                    .buttonStyle(.borderless)
                Button {
                    app.run { try await app.retry(id) }
                } label: {
                    Label("Retry", systemImage: "arrow.trianglehead.clockwise").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .disabled(v.job.cleanedUp || v.job.exportPending)
                iconButton("xmark", label: "Delete \(v.job.title)") {
                    app.gated { confirm in try await app.engine.jobsDelete(id, confirm: confirm) }
                }
            }
            if openLogs.contains(id) {
                log(id).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.top, 10)
            }
        }
    }

    // MARK: empty

    var empty: some View {
        VStack(spacing: 14) {
            Image(systemName: "shippingbox")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
                .frame(width: 56, height: 56)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            Text("Nothing in the queue").font(.title3.weight(.semibold))
            Text("Add photos on Generate and they'll show up here while Lift turns them into 3D models.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Go to Generate") { app.section = .generate }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 64).padding(.horizontal, 24)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
    }

    // MARK: pieces

    /// Rows inside one card, separated by hairlines.
    func rows(_ jobs: [JobView], @ViewBuilder row: @escaping (Int, JobView) -> some View) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(jobs.enumerated()), id: \.element.job.id) { i, v in
                if i > 0 { Divider() }
                row(i, v).padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
    }

    func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption.weight(.bold)).frame(width: 28, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(label)
        .help(label)
    }

    @ViewBuilder func priorityTag(_ p: Priority) -> some View {
        switch p {
        case .high: Tag(text: "High priority", color: .orange)
        case .low: Tag(text: "Low priority", color: .secondary)
        case .normal: EmptyView()
        }
    }

    func modelName(_ recipe: String) -> String {
        app.models.first { $0.id == recipe }?.name ?? recipe
    }

    func chain(_ v: JobView) -> String {
        v.steps.map { modelName($0.recipe) }.joined(separator: " → ")
    }

    func source(_ s: JobSource) -> String {
        switch s {
        case .ui: "from the app"
        case .http: "from the API"
        case .mcp: "from MCP"
        }
    }
}

/// Turns a list drag (`onMove` indices) into a `jobs_move` target; nil when the job stays put.
enum QueueOrder {
    static func target(_ ids: [String], from: Int, to: Int) -> MoveTarget? {
        guard ids.indices.contains(from), to != from, to != from + 1 else { return nil }
        return to < ids.count ? .before(ids[to]) : .after(ids[ids.count - 1])
    }
}

/// The photos a job was given: its first step's image inputs, a multi-view folder's images in name order.
enum JobPhotos {
    static func paths(_ v: JobView) -> [String] {
        guard let first = v.steps.first else { return [] }
        let images = Set(IOType.image.fileExtensions)
        let fm = FileManager.default
        return first.inputs.keys.sorted().flatMap { key -> [String] in
            let path = first.inputs[key]!
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return [] }
            if !isDir.boolValue { return images.contains(URL(filePath: path).pathExtension.lowercased()) ? [path] : [] }
            let names = (try? fm.contentsOfDirectory(atPath: path)) ?? []
            return names.filter { images.contains(URL(filePath: $0).pathExtension.lowercased()) }.sorted()
                .map { URL(filePath: path).appending(path: $0).path }
        }
    }
}

/// A running job's photos: one large, or a 2×2 grid (the fourth tile counts any more).
struct PhotoGrid: View {
    let paths: [String]

    var body: some View {
        if paths.count <= 1 {
            Thumbnail(path: paths.first, size: 124)
        } else {
            let shown = Array(paths.prefix(4))
            LazyVGrid(columns: [GridItem(.fixed(60), spacing: 4), GridItem(.fixed(60), spacing: 4)], spacing: 4) {
                ForEach(shown.indices, id: \.self) { i in
                    if i == 3 && paths.count > 4 {
                        Text("+\(paths.count - 3)").font(.headline).foregroundStyle(.secondary)
                            .frame(width: 60, height: 60)
                            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                    } else {
                        Thumbnail(path: shown[i], size: 60, radius: 7)
                    }
                }
            }
            .frame(width: 124)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(paths.count) photos")
        }
    }
}

/// A photo from disk, scaled down by Quick Look (full-size inputs can be 4096 px).
struct Thumbnail: View {
    let path: String?
    let size: CGFloat
    var radius: CGFloat = 8
    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            Color.white
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo").foregroundStyle(.gray)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .task(id: path) {
            guard let path else { image = nil; return }
            let request = QLThumbnailGenerator.Request(fileAt: URL(filePath: path), size: CGSize(width: size, height: size),
                                                       scale: scale, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
    }
}

/// A small colored label ("High priority", "Failed").
struct Tag: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: 5))
    }
}

/// A thin progress bar.
struct Meter: View {
    let fraction: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Color.accentColor).frame(width: g.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
    }
}

extension View {
    /// The Queue's card: a faint fill and hairline border that read in light and dark.
    func card(_ radius: CGFloat, stroke: Color = Color.primary.opacity(0.08)) -> some View {
        background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(stroke))
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}
