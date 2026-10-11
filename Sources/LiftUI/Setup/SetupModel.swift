import Foundation
import LiftCore
import LiftServer
import Observation

/// The first-launch wizard (spec §11). The working directory comes first because opening it starts the
/// engine, which runs the toolchain checks and installs, copies the bundled recipes and stores the token.
/// The step reached is saved, so a setup that was quit halfway resumes there (spec §1).
@MainActor @Observable
public final class SetupModel {
    public enum Step: Int, CaseIterable, Sendable {
        case folders, toolchain, recipes, huggingFace, mcp

        public var title: String {
            switch self {
            case .folders: "Where Lift keeps its files"
            case .toolchain: "Helper tools"
            case .recipes: "Models"
            case .huggingFace: "Hugging Face (optional)"
            case .mcp: "Connect an AI assistant"
            }
        }
    }

    public var step: Step
    public var workdir: URL
    /// Where finished models are saved (spec §11), and whether Lift then deletes its own copy.
    public var exportDir: URL
    public var cleanupAfterExport = false
    public private(set) var prereqs: Prereqs?
    public private(set) var log: [String] = []
    public private(set) var recipes: [RecipeListing] = []
    public private(set) var keptLocal: [String] = []
    public var hfToken = ""
    public private(set) var busy = false

    public init(app: AppModel) {
        workdir = app.workdir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Lift")
        step = app.lift == nil ? .folders : Step(rawValue: app.setupStep) ?? .folders
        exportDir = app.settings.exportDir.map { URL(filePath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Lift Exports")
        cleanupAfterExport = app.settings.cleanupAfterExport
    }

    public var missingTools: Bool {
        guard let t = prereqs?.tools else { return true }
        return t.brew == nil || t.git == nil || t.uv == nil
    }

    /// Gated weights the bundled recipes use: their pages, where the user accepts the authors' terms.
    public func gatedRepos(_ app: AppModel) -> [String] {
        Array(Set(app.models.flatMap { $0.recipe.weights.filter(\.gated).map(\.repo) })).sorted()
    }

    /// Loads what the current step shows (after a resume, too).
    public func load(_ app: AppModel) async {
        switch step {
        case .toolchain: await checkTools(app)
        case .recipes:
            recipes = await app.lift?.recipesList() ?? []
            keptLocal = await app.lift?.recipesBundleSync().keptLocal ?? []
        default: break
        }
    }

    /// Moves to the next step, doing that step's work first.
    public func next(_ app: AppModel) async {
        busy = true
        defer { busy = false }
        switch step {
        case .folders:
            guard await app.open(workdir, ready: false) else { return }
            do {
                _ = try await app.engine.settingsSet("export_dir", .string(exportDir.path))
                _ = try await app.engine.settingsSet("cleanup_after_export", .bool(cleanupAfterExport))
                await app.refresh()
            } catch { app.alert = Format.error(error); return }
        case .huggingFace:
            if !hfToken.isEmpty {
                do { _ = try await app.liveServer.secretsSetHFToken(hfToken) } catch { app.alert = Format.error(error); return }
                hfToken = ""
            }
        case .mcp:
            app.finishSetup()
            return
        default: break
        }
        step = Step(rawValue: step.rawValue + 1) ?? .mcp
        app.setupStep = step.rawValue
        await load(app)
    }

    public func checkTools(_ app: AppModel) async {
        prereqs = await app.lift?.systemPrereqs()
    }

    /// Installs missing tools (native Homebrew via one administrator dialog, then git and uv) with a live log.
    public func installTools(_ app: AppModel) {
        log = []
        let onLine: @Sendable (String) -> Void = { line in Task { @MainActor [weak self] in self?.log.append(line) } }
        app.gated { confirm in try await app.engine.systemInstallPrereqs(confirm: confirm, onLine: onLine) } then: { [weak self] in self?.prereqs = $0 }
    }
}
