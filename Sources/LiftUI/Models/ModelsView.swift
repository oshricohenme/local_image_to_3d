import AppKit
import LiftCore
import SwiftUI

/// Models (the approved redesign): a library of cards by what each model does, with search and filter chips;
/// a card opens the model's page. Download progress, Pause and Cancel live on the card. Recipes come only
/// from Lift (spec §4): no sources to add.
struct ModelsView: View {
    let app: AppModel
    @State private var path: [String] = []
    @State private var filter = LibraryFilter.all
    @State private var search = ""
    @State private var listings: [RecipeListing] = []

    var body: some View {
        NavigationStack(path: $path) {
            library
                .navigationDestination(for: String.self) { id in
                    ModelPageView(app: app, id: id) { if !path.isEmpty { path.removeLast() } }
                }
        }
        .task(id: app.models.count) { listings = await app.lift?.recipesList() ?? [] }
    }

    var library: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Models").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                    Text("Open-source models you can run on this Mac. Each one is made by its authors — Lift just runs it.")
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    TextField("Search models", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    ForEach(LibraryFilter.allCases, id: \.self) { f in
                        Toggle(f.rawValue, isOn: Binding(get: { filter == f }, set: { if $0 { filter = f } }))
                            .toggleStyle(.button).controlSize(.regular)
                    }
                }
                let sections = Library.sections(app.models, filter: filter, search: search)
                if sections.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No models here yet" : "No models match “\(search)”", systemImage: "shippingbox",
                                           description: Text(filter == .installed ? "Install one from All: it downloads in the background." : ""))
                }
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(section.title).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                            ForEach(section.models, id: \.id) { m in
                                ModelCardView(app: app, model: m) { path.append(m.id) }
                            }
                        }
                    }
                }
                let coming = Library.comingSoon(app.models)
                if !coming.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Coming with Lift updates").font(.headline).foregroundStyle(.secondary)
                        HStack(spacing: 12) {
                            ForEach(coming, id: \.self) { name in
                                Text(name).foregroundStyle(.secondary).frame(width: 140, height: 64)
                                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5])).foregroundStyle(.tertiary))
                            }
                        }
                    }
                }
                let problems = listings.filter { $0.state != .available && $0.state != .developerHidden }
                if !problems.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Recipes Lift can't use").font(.caption.bold())
                        ForEach(problems.indices, id: \.self) { i in
                            Text("\(problems[i].name ?? problems[i].id): \(problemText(problems[i]))").font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Models")
    }

    func problemText(_ l: RecipeListing) -> String {
        switch l.state {
        case .needsNewerLift: "needs a newer version of Lift"
        case .invalid: "the recipe has a mistake" + (app.developer ? " (\(l.detail ?? ""))" : "")
        case .shadowed: "your edited copy is used instead"
        case .available, .developerHidden: ""
        }
    }
}

/// The task's icon, for a model without a preview image.
func taskSymbol(_ m: ModelView) -> String {
    Library.isRigging(m) && !Library.isPhotoTo3D(m) ? "figure.walk" : "cube.transparent"
}

/// A model's preview: its README's first image, else a neutral tile with the task icon.
struct PreviewImage: View {
    let url: URL?
    let symbol: String

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary.opacity(0.6))
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(.secondary)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

/// One model in the library: preview, status chip, name and task, description, credit, license and size,
/// download progress with Pause and Cancel, and one action. Clicking it opens the model's page.
struct ModelCardView: View {
    let app: AppModel
    let model: ModelView
    let open: () -> Void

    var body: some View {
        let m = model
        let card = ModelCard(m, weightsBytes: m.download?.totalBytes ?? app.weightBytes[m.id])
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                PreviewImage(url: app.previews[m.id], symbol: taskSymbol(m)).frame(height: 150).frame(maxWidth: .infinity)
                Text(Library.chip(m, hfKey: app.secrets.get(.hfToken) != nil)).font(.caption.bold())
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(m.name).font(.headline)
                    Text(card.task).font(.caption).padding(.horizontal, 6).padding(.vertical, 2).background(.quaternary, in: Capsule())
                }
                if let d = card.description { Text(d).font(.callout).lineLimit(1) }
                Text("by " + m.recipe.attribution.authors.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(([m.recipe.attribution.license.spdx] + [card.size].compactMap { $0 }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                DownloadControls(app: app, model: m)
                CardActionButton(app: app, model: m)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(m.name), \(Library.chip(m, hfKey: app.secrets.get(.hfToken) != nil))")
        .accessibilityAction(named: "Open \(m.name)", open)
        .task(id: m.id) {
            await app.loadPreview(m)
            await app.loadWeightBytes(m)
        }
    }
}

/// The card's one action: Install, Use in Generate, Download now or Retry. While a download runs, its Pause
/// and Cancel sit next to the progress bar instead (`DownloadControls`).
struct CardActionButton: View {
    let app: AppModel
    let model: ModelView

    var body: some View {
        switch Library.action(model) {
        case .install?:
            Button("Install") { app.install(model) }.buttonStyle(.borderedProminent)
        case .useInGenerate?:
            Button("Use in Generate") { app.useInGenerate(model) }.buttonStyle(.borderedProminent)
        case .downloadNow?:
            if let d = model.download {
                Button("Download now") { app.run { _ = try await app.engine.downloadsReorder(d.id, position: 0) } }
                    .help("Moves it to the front of the download queue")
            }
        case .retry?:
            Button("Try Again") { retry(app, model) }
        case .pause?, .resume?, nil:
            EmptyView()
        }
    }
}

/// Try Again for a stopped or failed download, or files found missing: from what's already downloaded.
@MainActor func retry(_ app: AppModel, _ m: ModelView) {
    if let d = m.download, d.state == .failed || d.state == .cancelled {
        app.run { _ = try await app.engine.downloadsRetry(d.id) }
    } else {
        app.gated { confirm in try await app.engine.modelsDownloadWeights(m.id, confirm: confirm) }
    }
}

/// A model's download on its card, page or the menu bar: the bar, Pause/Resume and Cancel right next to it,
/// "5.2 of 20.1 GB · 12 MB/s · about 21 min left", and a warning when the disk is too full for the rest.
/// Code phases (no byte totals) show their plain name with an indeterminate bar.
struct DownloadControls: View {
    let app: AppModel
    let model: ModelView

    var body: some View {
        if let d = model.download, d.state != .done {
            VStack(alignment: .leading, spacing: 4) {
                if d.state.isActive {
                    HStack(spacing: 6) {
                        if let total = d.totalBytes, total > 0, d.state != .queued {
                            ProgressView(value: Double(d.downloadedBytes), total: Double(total))
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                        if d.state == .paused {
                            Button { app.run { _ = try await app.engine.downloadsResume(d.id) } } label: { Label("Resume download", systemImage: "play.fill") }
                                .help("Resume download")
                        } else {
                            Button { app.run { _ = try await app.engine.downloadsPause(d.id) } } label: { Label("Pause download", systemImage: "pause.fill") }
                                .help("Pause download")
                        }
                        Button { app.gated { confirm in try await app.engine.downloadsCancel(d.id, confirm: confirm) } } label: {
                            Label("Cancel download", systemImage: "xmark")
                        }
                        .help("Cancel download (what's downloaded stays, so it can resume later)")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                Text(Format.downloadLine(d, rate: app.rates[model.id])).font(.caption)
                    .foregroundStyle(d.state == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                if d.state == .failed, let link = d.link { Link("Open the terms page", destination: link).font(.caption) }
                if d.state.isActive, let warning = Format.spaceWarning(free: app.hubFreeBytes, remaining: max(0, (d.totalBytes ?? 0) - d.downloadedBytes)) {
                    Label(warning, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
            .accessibilityElement(children: .contain)
        } else if case .installing = model.status {
            InstallProgressRow(app: app, model: model)
        } else if case .installFailed(_, _, let reason) = model.status {
            Label(reason, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                .lineLimit(3).help(reason)
        }
    }
}

/// A model's install while its code is being set up: an indeterminate bar and the phase in plain words.
struct InstallProgressRow: View {
    let app: AppModel
    let model: ModelView

    var body: some View {
        if let line = app.installLine(model) {
            VStack(alignment: .leading, spacing: 4) {
                if let p = model.progress, p.totalBytes > 0 {
                    ProgressView(value: Double(p.downloadedBytes), total: Double(p.totalBytes))
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(model.name): \(line)")
        }
    }
}
