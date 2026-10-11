import Foundation
import LiftCore
import LiftServer
import Observation

/// The first-launch wizard (spec §11): Welcome → Your files → Your Mac → First model → Access (only for a model
/// with gated weights) → Done. The working directory comes first because opening it starts the engine, which
/// checks the tools, copies the bundled recipes and stores the token. The step reached is saved, so a setup
/// that was quit halfway resumes there (spec §1). Nothing big downloads until the user presses Install.
@MainActor @Observable
public final class SetupModel {
    public enum Step: String, CaseIterable, Sendable {
        case welcome, files, mac, model, access, done

        /// The step rail's label; Welcome has no rail.
        public var title: String? {
            switch self {
            case .welcome: nil
            case .files: "Your files"
            case .mac: "Your Mac"
            case .model: "First model"
            case .access: "Access (if needed)"
            case .done: "Done"
            }
        }

        /// A saved step, including the older wizard's numbers (folders, tools, recipes, Hugging Face, MCP).
        init?(saved: String?) {
            let older: [String: Step] = ["0": .files, "1": .mac, "2": .model, "3": .model, "4": .done]
            guard let saved, let step = Step(rawValue: saved) ?? older[saved] else { return nil }
            self = step
        }
    }

    /// A model offered as the first one: what it does, who made it, how big it is and what it asks of you.
    public struct ModelCard: Identifiable, Equatable, Sendable {
        public var id: String
        public var name: String
        /// The image → 3D task's own label, e.g. "Photo → 3D model".
        public var task: String
        public var description: String?
        /// "by <authors> · <license>".
        public var credit: String
        public var size: String?
        /// Hugging Face repos whose authors ask you to accept their terms first.
        public var gated: [String]
        /// The attribution components behind `gated`, by name.
        public var gatedNames: [String]
        public var restrictions: [String]
        public var unsupported: String?
    }

    public enum ToolState: Equatable, Sendable {
        case ready, needed, installing
        case failed(String)
    }

    public struct ToolRow: Equatable, Sendable {
        public var name: String
        public var detail: String
        public var state: ToolState
    }

    static let chosenKey = "setupModel"

    public var step: Step
    public var workdir: URL
    /// Where finished models are saved (spec §11), and whether Lift then deletes its own copy.
    public var exportDir: URL
    public var cleanupAfterExport = false
    public internal(set) var prereqs: Prereqs?
    public internal(set) var installingTools = false
    public internal(set) var installedTools = false
    public internal(set) var toolsFailure: String?
    public private(set) var log: [String] = []
    /// The card picked on the First model step, and the model setup is getting ready.
    public var selected: String?
    public internal(set) var chosen: ModelCard?
    /// Weight sizes from Hugging Face, by model id.
    public private(set) var sizes: [String: Int] = [:]
    public var hfToken = ""
    public private(set) var hfUser: String?
    public private(set) var tokenProblem: String?
    public private(set) var repoAccess: [String: Bool] = [:]
    public private(set) var busy = false

    let hf: any HFAccount
    let freeSpace: (URL) -> Int64?

    public init(app: AppModel, hf: any HFAccount, freeSpace: @escaping (URL) -> Int64? = SetupModel.volumeFree) {
        self.hf = hf
        self.freeSpace = freeSpace
        workdir = app.workdir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Lift")
        exportDir = app.settings.exportDir.map { URL(filePath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Lift Exports")
        cleanupAfterExport = app.settings.cleanupAfterExport
        let id = app.defaults.string(forKey: Self.chosenKey)
        let chosen = Self.cards(app.models, developer: app.developer, sizes: [:]).first { $0.id == id }
        let saved = app.lift == nil ? .welcome : Step(saved: app.setupStep) ?? .files
        step = saved == .access && chosen?.gated.isEmpty != false ? .model : saved
        self.chosen = chosen
        selected = chosen?.id
    }

    /// The folder picked in Your files: Lift's files go in a "Lift" folder inside it, never loose among the user's.
    public func choose(_ folder: URL) {
        workdir = folder.appending(path: "Lift")
    }

    // MARK: steps

    func following(_ s: Step) -> Step {
        switch s {
        case .model: chosen?.gated.isEmpty == false ? .access : .done
        case .done: .done
        default: Step.allCases[Step.allCases.firstIndex(of: s)! + 1]
        }
    }

    func preceding(_ s: Step) -> Step {
        switch s {
        case .welcome: .welcome
        case .done: chosen?.gated.isEmpty == false ? .access : .model
        default: Step.allCases[Step.allCases.firstIndex(of: s)! - 1]
        }
    }

    func go(_ s: Step, _ app: AppModel) async {
        step = s
        app.setupStep = s.rawValue
        await load(app)
    }

    /// Loads what the current step shows (after a resume, too).
    public func load(_ app: AppModel) async {
        switch step {
        case .mac: await checkTools(app)
        case .model:
            for m in app.models where sizes[m.id] == nil && cards(app).contains(where: { $0.id == m.id }) && !m.recipe.weights.isEmpty {
                if let bytes = await hf.size(of: m.recipe.weights) { sizes[m.id] = bytes }
            }
        case .access:
            if hfUser == nil && app.secrets.get(.hfToken) != nil { await checkToken(app) }
        default: break
        }
    }

    /// Continue: does the current step's work, then moves on.
    public func next(_ app: AppModel) async {
        busy = true
        defer { busy = false }
        switch step {
        case .files:
            guard await app.open(workdir, ready: false) else { return }
            do {
                _ = try await app.engine.settingsSet("export_dir", .string(exportDir.path))
                _ = try await app.engine.settingsSet("cleanup_after_export", .bool(cleanupAfterExport))
                await app.refresh()
            } catch { app.alert = Format.error(error); return }
        case .mac:
            guard macReady else { return }
        case .model:
            await installChosen(app)
            return
        case .access:
            guard accessGranted else { return }
            install(app)
        case .done:
            finish(app)
            return
        case .welcome: break
        }
        await go(following(step), app)
    }

    public func back(_ app: AppModel) async {
        await go(preceding(step), app)
    }

    public func finish(_ app: AppModel) {
        app.finishSetup()
        app.section = .generate
    }

    // MARK: your files

    /// How much room the workdir's volume has, in plain words, and whether that's too little.
    public var space: (text: String, warning: Bool)? {
        freeSpace(workdir).map(Self.spaceNote)
    }

    static func spaceNote(_ free: Int64) -> (text: String, warning: Bool) {
        let lead = "Models are large — each one needs about 6 to 20 GB."
        let gb = free / 1_000_000_000
        if free < 25_000_000_000 {
            return ("\(lead) This Mac has only \(gb) GB free, which may not be enough. Free up some space, or choose a folder on a bigger drive.", true)
        }
        let n = free / 20_000_000_000
        return ("\(lead) This Mac has \(gb) GB free, enough for about \(n) model\(n == 1 ? "" : "s").", false)
    }

    /// Free space for important data on the volume that holds `url` (or would, once it's created).
    public nonisolated static func volumeFree(_ url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path) && u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// "Library › Application Support › Lift": the folders under your home, or the last three elsewhere.
    public static func breadcrumb(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.pathComponents
        var parts = url.standardizedFileURL.pathComponents
        if parts.starts(with: home) && parts.count > home.count {
            parts.removeFirst(home.count)
        } else {
            parts = Array(parts.filter { $0 != "/" && $0 != "Volumes" }.suffix(3))
        }
        return parts.joined(separator: " › ")
    }

    /// "A “Lift” folder in your Library".
    public static func friendlyName(_ url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        let place = switch parent.standardizedFileURL {
        case FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL: "your home folder"
        default: parent.lastPathComponent == "Application Support" ? "your Library" : parent.lastPathComponent
        }
        return "A “\(url.lastPathComponent)” folder in \(place)"
    }

    // MARK: your Mac

    public func checkTools(_ app: AppModel) async {
        prereqs = await app.lift?.systemPrereqs(checkMetal: app.needsMetalToolchain)
    }

    /// The checklist: each tool, what it's for, and where it stands. Apple's graphics compiler only when a recipe needs it.
    public var toolRows: [ToolRow] {
        guard let p = prereqs else { return [] }
        var rows = [("Homebrew", "installs Mac tools for Lift", p.tools.brew != nil),
                    ("git", "downloads each model's code", p.tools.git != nil),
                    ("uv", "sets up the Python each model needs", p.tools.uv != nil)]
        if let metal = p.metalToolchain { rows.append(("Apple's graphics compiler", "some models need it", metal)) }
        return rows.map { name, detail, ok in
            ToolRow(name: name, detail: detail, state: ok ? .ready : installingTools ? .installing : toolsFailure.map(ToolState.failed) ?? .needed)
        }
    }

    public var macReady: Bool { prereqs != nil && toolRows.allSatisfy { $0.state == .ready } }
    /// Set Up My Mac (or Try Again after a failure).
    public var offerSetUp: Bool { prereqs != nil && !macReady && !installingTools }
    /// Installing native Homebrew is the one moment macOS asks for the password.
    public var askPasswordNote: Bool { prereqs != nil && prereqs?.tools.brew == nil }

    public var macStatus: String? {
        guard macReady else { return nil }
        return installedTools ? "Your Mac is ready ✓" : "Your Mac already has everything Lift needs ✓"
    }

    public var rosettaNote: String? {
        guard let t = prereqs?.tools, t.rosettaBrew != nil, t.brew == nil else { return nil }
        return "We found an older copy of Homebrew made for Intel Macs. Lift leaves it alone and adds the Apple-silicon version."
    }

    /// Set Up My Mac: installs what's missing (native Homebrew via one administrator dialog, then git and uv,
    /// and Apple's graphics compiler when needed) with a live log. Pressing the button is the go-ahead.
    public func setUpMac(_ app: AppModel) async {
        log = []
        toolsFailure = nil
        installingTools = true
        defer { installingTools = false }
        let onLine: @Sendable (String) -> Void = { line in Task { @MainActor [weak self] in self?.log.append(line) } }
        do {
            prereqs = try await app.engine.systemInstallPrereqs(metal: app.needsMetalToolchain, confirm: true, onLine: onLine).value
            installedTools = true
        } catch {
            toolsFailure = Format.error(error)
            await checkTools(app)
        }
    }

    // MARK: first model

    /// Image → 3D recipes the user can see: the choices for a first model.
    public func cards(_ app: AppModel) -> [ModelCard] {
        Self.cards(app.models, developer: app.developer, sizes: sizes)
    }

    /// Everything else (e.g. rigging): added later, not a first model.
    public func addOns(_ app: AppModel) -> [ModelCard] {
        app.models.filter { Self.visible($0, developer: app.developer) && Self.imageTask($0.recipe) == nil }.map { Self.card($0, sizes: sizes) }
    }

    static func cards(_ models: [ModelView], developer: Bool, sizes: [String: Int]) -> [ModelCard] {
        models.filter { visible($0, developer: developer) && imageTask($0.recipe) != nil }.map { card($0, sizes: sizes) }
    }

    static func visible(_ m: ModelView, developer: Bool) -> Bool { !m.recipe.developer || developer }

    static func imageTask(_ r: Recipe) -> RecipeTask? {
        r.tasks.first { $0.inputs.first?.type == .image && $0.output == .mesh }
    }

    static func card(_ m: ModelView, sizes: [String: Int]) -> ModelCard {
        let r = m.recipe, a = r.attribution
        let gated = r.weights.filter(\.gated).map(\.repo)
        let restrictions = a.components.flatMap { c in
            c.restrictions.map { $0 == "non-commercial" ? "Not for commercial use: \(c.name) (\(c.license.spdx))" : "\(c.name): \($0)" }
        }
        let bytes = sizes[m.id] ?? Int(r.resources.diskGB * 1_000_000_000)
        var unsupported: String?
        if case .unsupported(let reason) = m.status { unsupported = reason }
        return ModelCard(id: m.id, name: m.name, task: (imageTask(r) ?? r.tasks.first)?.label ?? "", description: r.description,
                         credit: "by \(a.authors.joined(separator: ", ")) · \(a.license.spdx)",
                         size: bytes > 0 ? "About " + (Double(bytes) / 1e9).formatted(.number.precision(.fractionLength(0...1))) + " GB" : nil,
                         gated: gated,
                         gatedNames: gated.map { repo in a.components.first { $0.url.path() == "/" + repo }?.name ?? repo },
                         restrictions: restrictions, unsupported: unsupported)
    }

    /// Install <Model>: remembers the choice, then shows the one-time About sheet and starts the install in the
    /// background. A model with gated weights installs after the Access step instead (it needs the key).
    public func installChosen(_ app: AppModel) async {
        guard let card = cards(app).first(where: { $0.id == selected }) else { return }
        chosen = card
        app.defaults.set(card.id, forKey: Self.chosenKey)
        if card.gated.isEmpty { install(app) }
        await go(following(.model), app)
    }

    public func skipModel(_ app: AppModel) async {
        chosen = nil
        app.defaults.set(nil, forKey: Self.chosenKey)
        await go(.done, app)
    }

    func install(_ app: AppModel) {
        if let m = app.models.first(where: { $0.id == chosen?.id }) { app.install(m) }
    }

    // MARK: access

    /// "RMBG-2.0 by BRIA AI", or several joined with "and".
    public var accessComponents: String {
        ListFormatter.localizedString(byJoining: chosen?.gatedNames ?? [])
    }

    /// Check: verifies the pasted key (or the one already kept), keeps it in the Keychain once Hugging Face
    /// accepts it, then asks about each gated repo. A refused key isn't kept.
    public func checkToken(_ app: AppModel) async {
        let pasted = hfToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = pasted.isEmpty ? app.secrets.get(.hfToken) : pasted else { return }
        busy = true
        defer { busy = false }
        tokenProblem = nil
        do {
            guard let user = try await hf.whoami(token: token) else {
                hfUser = nil
                repoAccess = [:]
                tokenProblem = "Hugging Face didn't accept this key. Copy it again from the token page: it starts with “hf_”."
                return
            }
            hfUser = user
            if !pasted.isEmpty {
                _ = try await app.liveServer.secretsSetHFToken(token)
                hfToken = ""
            }
            for repo in chosen?.gated ?? [] {
                repoAccess[repo] = try await hf.canAccess(repo: repo, token: token)
            }
        } catch {
            tokenProblem = "Lift couldn't reach Hugging Face. Check your internet connection, then press Check again. (\(Format.error(error)))"
        }
    }

    public var accessGranted: Bool {
        guard let chosen, hfUser != nil else { return false }
        return chosen.gated.allSatisfy { repoAccess[$0] == true }
    }

    /// Skip for now: setup goes on; the model installs later, from Models, once it has access.
    public func skipAccess(_ app: AppModel) async {
        await go(.done, app)
    }

    // MARK: done

    /// Where the chosen model's install stands, from LiftCore's status.
    public func installStatus(_ app: AppModel) -> String? {
        guard let chosen, let m = app.models.first(where: { $0.id == chosen.id }) else { return nil }
        switch m.status {
        case .installing(let phase): return "Getting \(m.name) ready: \(phase)…"
        case .installed, .updateAvailable: return "\(m.name) is installed and ready."
        case .notInstalled where !chosen.gated.isEmpty && !accessGranted:
            return "\(m.name) is waiting for Hugging Face access. You can finish that later in Models."
        case .notInstalled: return "\(m.name) isn't installed yet."
        case .installFailed: return "\(m.name) couldn't be installed. Models shows what happened."
        default: return "\(m.name): \(Format.status(m.status))"
        }
    }

    /// A photo dropped on Done: setup finishes and Generate opens with it and the chosen model.
    public func drop(_ urls: [URL], _ app: AppModel) {
        guard let photo = urls.first(where: { IOType.image.fileExtensions.contains($0.pathExtension.lowercased()) }) else { return }
        finish(app)
        if let id = chosen?.id, let m = app.models.first(where: { $0.id == id }), let t = Self.imageTask(m.recipe) {
            app.generate.use(photo.path, for: TaskRef(recipe: id, task: t.id))
        } else {
            app.generate.add([photo])
        }
    }
}
