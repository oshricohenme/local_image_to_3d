import Foundation
import LiftCore
import LiftServer
import Observation

/// Setup (spec §11): only the steps for what's missing at this launch (`AppModel.needs`). A first run gets
/// Welcome → Your files → (Your Mac) → You're all set; a later launch gets just the fix, e.g. Your Mac when uv
/// is gone, then the main window. Models, Hugging Face access and the first try live in Models and Generate.
@MainActor @Observable
public final class SetupModel {
    public enum Step: String, CaseIterable, Sendable {
        case welcome, files, mac, done

        /// The step rail's label; Welcome has no rail.
        public var title: String? {
            switch self {
            case .welcome: nil
            case .files: "Your files"
            case .mac: "Your Mac"
            case .done: "Done"
            }
        }
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

    /// The steps shown at this launch, in order.
    public let steps: [Step]
    public private(set) var step: Step
    public let firstRun: Bool
    /// Why the saved workdir didn't open (a later launch's Your files).
    public let workdirProblem: String?
    public var workdir: URL
    /// Where finished models are saved (spec §11), and whether Lift then deletes its own copy.
    public var exportDir: URL
    public var cleanupAfterExport = false
    public internal(set) var prereqs: Prereqs?
    public internal(set) var installingTools = false
    public internal(set) var installedTools = false
    public internal(set) var toolsFailure: String?
    public private(set) var log: [String] = []
    public private(set) var busy = false

    let freeSpace: (URL) -> Int64?

    public init(app: AppModel, freeSpace: @escaping (URL) -> Int64? = SetupModel.volumeFree) {
        self.freeSpace = freeSpace
        let n = app.needs
        steps = (n.firstRun ? [.welcome] : []) + (n.files ? [.files] : []) + (n.mac ? [.mac] : []) + (n.firstRun ? [.done] : [])
        step = steps.first ?? .done
        firstRun = n.firstRun
        workdirProblem = n.workdirProblem
        prereqs = app.prereqs
        workdir = app.workdir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Lift")
        exportDir = app.settings.exportDir.map { URL(filePath: $0) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "Lift Exports")
        cleanupAfterExport = app.settings.cleanupAfterExport
    }

    /// The folder picked in Your files: Lift's files go in a "Lift" folder inside it, never loose among the user's.
    public func choose(_ folder: URL) {
        workdir = folder.appending(path: "Lift")
    }

    // MARK: steps

    /// Above the rail: "Set up Lift" on a first run, else how much there is to fix.
    public var railTitle: String {
        let fixes = steps.count
        return firstRun ? "Set up Lift" : fixes == 1 ? "Lift needs to fix one thing" : "Lift needs to fix \(fixes) things"
    }

    /// The current step's title, in plain words for a first run or a repair.
    public var heading: String {
        switch step {
        case .welcome: "Turn photos into 3D models, right on your Mac"
        case .files: firstRun ? "Where should Lift keep its files?" : "Lift can't find its folder"
        case .mac: firstRun ? "Get your Mac ready" : "A helper tool is missing"
        case .done: "You're all set"
        }
    }

    /// Continue: does the current step's work, then moves on; after the last step, the main window.
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
        case .welcome, .done: break
        }
        if let i = steps.firstIndex(of: step), i + 1 < steps.count {
            step = steps[i + 1]
        } else {
            app.finishSetup()
            app.section = .generate
        }
    }

    public func back(_ app: AppModel) async {
        if let i = steps.firstIndex(of: step), i > 0 { step = steps[i - 1] }
    }

    public var canGoBack: Bool { steps.firstIndex(of: step) ?? 0 > 0 }

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

    /// The checklist: each tool, what it's for, and where it stands. Apple's graphics compiler only when a recipe needs it.
    public var toolRows: [ToolRow] {
        guard let p = prereqs else { return [] }
        var rows = [("Homebrew", "installs Mac tools for Lift", p.tools.brew != nil),
                    ("git", "downloads each model's code", p.tools.git != nil),
                    ("git-lfs", "downloads the large files some models keep with their code", p.tools.gitLfs != nil),
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
            prereqs = await app.checkTools() ?? prereqs
        }
    }
}
