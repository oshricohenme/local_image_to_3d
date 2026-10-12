import CryptoKit
import Foundation

/// Where a model stands (spec §6). `installing` and the weights states come from the engine.
public enum ModelStatus: Codable, Sendable, Equatable {
    case notInstalled
    /// `phase`: installing, downloading weights, verifying weights.
    case installing(phase: String)
    case installed(commit: String?)
    /// Installed, but the source recipe (or its pin) changed since. Reinstall to update.
    case updateAvailable(installedCommit: String?, recipeCommit: String?)
    /// `reason`: which step failed and why, in plain words (`InstallFailure`); the full output is in install.log.
    case installFailed(command: String, exitCode: Int32, reason: String)
    case unsupported(reason: String)
    /// Installed, but the last weights check found files missing / wrong.
    case weightsMissing([WeightProblem])
    case weightsCorrupt([WeightProblem])
}

/// `models/<id>/state.json`: written last, so a partial install never counts as installed.
struct InstallState: Codable {
    var installed: Bool
    var commit: String?
    /// SHA-256 of the source recipe.yaml + launcher.py at install time.
    var digest: String
    var failedCommand: String?
    var exitCode: Int32?
    /// Why it failed, for any failure.
    var reason: String?
    var at: Date
}

/// A failed install step in plain words: the step, then the cause, picked out of the command's output.
enum InstallFailure {
    static func explain(command: String?, output: String) -> String {
        let tool = command?.split(separator: " ").first.map { URL(fileURLWithPath: String($0)).lastPathComponent }
        let step = switch tool {
        case "git"?: "Getting the code from GitHub"
        case "uv"?: "Setting up Python"
        case "brew"?: "Installing tools with Homebrew"
        case nil: "The install"
        default: "Checking the install"
        }
        return "\(step) failed: \(cause(output))"
    }

    static func cause(_ output: String) -> String {
        if let m = output.firstMatch(of: /([\w.+-]+): command not found/) { return "a program it needs, \(m.1), isn't installed." }
        if output.contains("No space left on device") { return "your Mac is out of disk space. Free up some space and try again." }
        if ["Could not resolve host", "Failed to connect", "Network is unreachable", "Connection timed out"].contains(where: output.contains) {
            return "Lift couldn't reach the internet. Check your connection and try again."
        }
        // Otherwise the last error line, else the last line that isn't the command itself or progress.
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("`") && !$0.contains("%") }
        let errorLine = lines.last { $0.lowercased().hasPrefix("error") || $0.hasPrefix("fatal:") }
        var line = errorLine ?? lines.last ?? "no details were given."
        for prefix in ["fatal: ", "error: ", "Error: ", "ERROR: "] where line.hasPrefix(prefix) { line.removeFirst(prefix.count) }
        return String(line.prefix(300))
    }
}

public struct UpstreamStatus: Codable, Sendable, Equatable {
    public var pin: String?
    public var head: String
    /// Commits upstream is past the pin; nil when not installed (only `git ls-remote` was run).
    public var commitsAhead: Int?
}

/// brew prerequisites → clone pinned commit → uv venv → install steps → substitutes → lift_shim + .pth →
/// recipe copy → smoke import; then, separately, weight downloads. Only ever writes inside `models/<id>/`
/// (and, through `brew` and `hf download`, Homebrew's prefix and the Hugging Face cache).
public struct Installer: Sendable {
    let runner: any CommandRunner
    let models: URL
    let workerRuntime: URL
    let tools: ToolPaths
    let toolEnvironment: [String: String]
    let hfToken: @Sendable () -> String?
    let hfHub: URL

    public init(runner: any CommandRunner, models: URL, workerRuntime: URL, tools: ToolPaths,
                toolEnvironment: [String: String], hfToken: @escaping @Sendable () -> String?, hfHub: URL) {
        self.runner = runner
        self.models = models
        self.workerRuntime = workerRuntime
        self.tools = tools
        self.toolEnvironment = toolEnvironment
        self.hfToken = hfToken
        self.hfHub = hfHub
    }

    /// Native Homebrew's prefix (`/opt/homebrew`), from the detected brew.
    var brewPrefix: String? { tools.brew.map { URL(filePath: $0).deletingLastPathComponent().deletingLastPathComponent().path } }

    public func dir(_ id: String) -> URL { models.appending(path: id) }
    public func logURL(_ id: String) -> URL { dir(id).appending(path: "install.log") }
    func stateURL(_ id: String) -> URL { dir(id).appending(path: "state.json") }
    public func venvPython(_ id: String) -> String { dir(id).appending(path: "venv/bin/python").path }
    /// The installed copy of the recipe folder; workers run this, not the source.
    public func installedRecipeDir(_ id: String) -> URL { dir(id).appending(path: "recipe") }
    public func shimURL(_ id: String) -> URL { dir(id).appending(path: "shim.json") }

    /// Every file of a recipe folder (recipe.yaml, launcher.py, files/…), by path and content.
    static func digest(_ recipeDir: URL) -> String {
        var hash = SHA256()
        let files = FileManager.default.enumerator(atPath: recipeDir.path)?.compactMap { $0 as? String } ?? []
        for path in files.filter({ !$0.contains("__pycache__") }).sorted() {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: recipeDir.appending(path: path).path, isDirectory: &isDir), !isDir.boolValue else { continue }
            hash.update(data: Data(path.utf8))
            hash.update(data: (try? Data(contentsOf: recipeDir.appending(path: path))) ?? Data())
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// What an install builds from. Anything else in a recipe (its launcher and files, settings, phases,
    /// progress names, messages) is only how the model runs, and is refreshed without reinstalling.
    static func installDigest(_ r: Recipe) -> String {
        struct Inputs: Encodable {
            var repo, commit: String?
            var python: String
            var install, substitutes, brew: [String]
            var shim: Recipe.Shim?
            var metalToolchain: Bool
            var weights: [Recipe.Weight]
        }
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        let data = (try? e.encode(Inputs(repo: r.repo, commit: r.commit, python: r.python, install: r.install, substitutes: r.substitutes,
                                         brew: r.brew, shim: r.shim, metalToolchain: r.metalToolchain, weights: r.weights))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Copies a changed recipe folder over the installed copy when only how the model runs changed: same code,
    /// same install. Returns whether it did. A worker already running keeps what it loaded; the next one uses this.
    @discardableResult
    public func refreshRecipe(_ entry: CatalogEntry, pin: String?) -> Bool {
        let id = entry.recipe.id
        guard var state = readState(id), state.installed, state.commit == (pin ?? entry.recipe.commit),
              state.digest != Self.digest(entry.directory), let current = installedRecipe(id),
              Self.installDigest(current) == Self.installDigest(entry.recipe) else { return false }
        let fm = FileManager.default
        let staged = dir(id).appending(path: "recipe.new")
        do {
            try? fm.removeItem(at: staged)
            try fm.copyItem(at: entry.directory, to: staged)
            _ = try fm.replaceItemAt(installedRecipeDir(id), withItemAt: staged)
            state.digest = Self.digest(entry.directory)
            try writeState(state, id: id)
            return true
        } catch {
            try? fm.removeItem(at: staged)
            return false
        }
    }

    func readState(_ id: String) -> InstallState? {
        guard let data = try? Data(contentsOf: stateURL(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(InstallState.self, from: data)
    }

    func writeState(_ state: InstallState, id: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: stateURL(id))
    }

    /// Status from the files on disk. `source` is the recipe as the sources have it now (nil if gone).
    public func status(id: String, source: CatalogEntry?, pin: String?) -> ModelStatus {
        guard let state = readState(id) else {
            if let source, source.recipe.platform.status == .unsupported {
                return .unsupported(reason: source.recipe.platform.reason ?? "")
            }
            return .notInstalled
        }
        guard state.installed else {
            return .installFailed(command: state.failedCommand ?? state.reason ?? "", exitCode: state.exitCode ?? -1,
                                  reason: InstallFailure.explain(command: state.failedCommand, output: state.reason ?? ""))
        }
        if let source, state.digest != Self.digest(source.directory) || state.commit != (pin ?? source.recipe.commit) {
            return .updateAvailable(installedCommit: state.commit, recipeCommit: pin ?? source.recipe.commit)
        }
        return .installed(commit: state.commit)
    }

    /// The installed recipe, read from the model's own copy.
    public func installedRecipe(_ id: String) -> Recipe? {
        guard readState(id)?.installed == true, case .ok(let recipe) = RecipeLoad.read(directory: installedRecipeDir(id), matchFolder: false) else { return nil }
        return recipe
    }

    /// Checks that run before anything is touched: platform, tools, native brew for `brew:` packages,
    /// Hugging Face token, disk space, substitutes. Returns the substitute registry and the `LIFT_SHIM` config.
    public func preflight(_ entry: CatalogEntry) throws -> (registry: [String: Substitute], shim: ShimConfig?) {
        let recipe = entry.recipe
        guard recipe.platform.status == .supported else {
            throw LiftError.prerequisite("\(recipe.name) is unsupported on this Mac: \(recipe.platform.reason ?? "")")
        }
        guard tools.git != nil, tools.uv != nil else { throw LiftError.prerequisite("git and uv are required; run system_install_prereqs") }
        if !recipe.brew.isEmpty && tools.brew == nil {
            throw LiftError.prerequisite("\(recipe.name) needs native Homebrew for \(recipe.brew.joined(separator: ", ")); run system_install_prereqs")
        }
        if recipe.weights.contains(where: \.gated) && hfToken() == nil {
            let gated = recipe.weights.filter(\.gated).map(\.repo).joined(separator: ", ")
            throw LiftError.prerequisite("\(recipe.name) needs a Hugging Face token with access to \(gated)")
        }
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
        let needed = Int64(recipe.resources.diskGB * 1_000_000_000)
        if let free = (try? models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw LiftError.prerequisite("not enough disk space: \(recipe.resources.diskGB) GB needed, \(Double(free) / 1e9) GB free")
        }
        let registry = try Substitute.registry(shared: entry.shared)
        return (registry, try ShimConfig.build(recipe, registry: registry))
    }

    /// Runs the whole install. Every command and its output go to `install.log` and `onLine`; `onPhase` gets
    /// "getting the code", "setting up python" and "checking the install" as each begins.
    /// Throws `LiftError.prerequisite` before touching anything, or `.commandFailed` with the log kept
    /// and state.json marked failed. Cancelled, it stops before the next command and marks nothing failed.
    public func install(_ entry: CatalogEntry, pin: String?, onLine: @escaping @Sendable (String) -> Void,
                        onPhase: @Sendable (String) async -> Void = { _ in }) async throws {
        let (registry, shimConfig) = try preflight(entry)
        if entry.recipe.metalToolchain, try await runner.run(ShellCommand("/usr/bin/xcrun", ["metal", "--version"]), onLine: { _ in }) != 0 {
            throw LiftError.prerequisite("\(entry.recipe.name) needs Apple's Metal Toolchain; install it from Setup (system_install_prereqs with metal)")
        }
        let recipe = entry.recipe
        let commit = pin ?? recipe.commit
        let git = tools.git!, uv = tools.uv!
        let fm = FileManager.default
        let root = dir(recipe.id)
        // repo/ is converged in place below (spec §6: Lift owns its working copy); the rest is rebuilt.
        for name in ["venv", "deps", "recipe", "state.json", "shim.json", "install.log"] {  // deps/: substitutes' clones and builds
            try? fm.removeItem(at: root.appending(path: name))
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let log = try LogFile(logURL(recipe.id))
        let lines: @Sendable (String) -> Void = { line in
            log.write(line)
            onLine(line)
        }
        let venv = root.appending(path: "venv").path
        var env = toolEnvironment
        env["PATH"] = "\(venv)/bin:" + (toolEnvironment["PATH"] ?? "/usr/bin:/bin")
        env["VIRTUAL_ENV"] = venv
        let repo = root.appending(path: "repo").path

        var steps: [ShellCommand] = []
        steps.append(ShellCommand(uv, ["venv", "--python", recipe.python, venv], environment: toolEnvironment, workingDirectory: root.path))
        let shell = recipe.install + recipe.substitutes.flatMap { registry[$0]?.install ?? [] }
        steps += shell.map { ShellCommand("/bin/sh", ["-c", $0], environment: env, workingDirectory: root.path) }
        if shimConfig != nil {
            // Editable: the venv imports the shim from shared/, which every app update refreshes, so a shim fix
            // reaches installed models without a reinstall. A plain install froze the install-day copy.
            steps.append(ShellCommand(uv, ["pip", "install", "-e", entry.shared.appending(path: "lift_shim").path], environment: env, workingDirectory: root.path))
            steps.append(ShellCommand(venvPython(recipe.id), ["-c", "import site, lift_shim.pth as p; p.write_pth(site.getsitepackages()[0])"], environment: env))
        }

        do {
            await onPhase("getting the code")
            if !recipe.brew.isEmpty, let brew = tools.brew {
                // First, so install steps that build native code can link against them.
                try await logged(ShellCommand(brew, ["install"] + recipe.brew, environment: toolEnvironment), lines)
            }
            if let url = recipe.repo, let commit {
                try await ensureRepo(url: url, commit: commit, at: URL(filePath: repo), git: git, lines: lines)
            } else {
                try fm.createDirectory(atPath: repo, withIntermediateDirectories: true)
            }
            await onPhase("setting up python")
            for step in steps { try await logged(step, lines) }
            try fm.copyItem(at: entry.directory, to: installedRecipeDir(recipe.id))
            if let shimConfig { try shimConfig.json.write(to: shimURL(recipe.id), atomically: true, encoding: .utf8) }
            let smoke = ShellCommand(venvPython(recipe.id), ["-m", "lift_worker", "--check", workerConfig(recipe, heartbeat: 2)],
                                     environment: workerEnvironment(recipe), workingDirectory: repo)
            await onPhase("checking the install")
            try await logged(smoke, lines)
            try writeState(InstallState(installed: true, commit: commit, digest: Self.digest(entry.directory), at: Date()), id: recipe.id)
            lines("installed \(recipe.id)")
        } catch {
            if error is CancellationError || Task.isCancelled {
                lines("install cancelled")
                throw error
            }
            // Any failure, not only a failing command, leaves a failed state with its reason (M10).
            if case LiftError.commandFailed(let command, let code, _) = error {
                try? writeState(InstallState(installed: false, commit: commit, digest: "", failedCommand: command, exitCode: code, reason: "\(error)", at: Date()), id: recipe.id)
            } else {
                try? writeState(InstallState(installed: false, commit: commit, digest: "", failedCommand: nil, exitCode: -1, reason: "\(error)", at: Date()), id: recipe.id)
            }
            lines("install failed: \(error)")
            throw error
        }
    }

    func logged(_ command: ShellCommand, _ lines: @escaping @Sendable (String) -> Void) async throws {
        try Task.checkCancellation()
        lines("$ \(command.display)")
        try await runner.check(command, onLine: lines)
    }

    /// Brings `repo` to exactly `commit` whatever state it's in (spec §6, Lift owns its working copy).
    /// A healthy clone of the same remote is fetched, force-checked-out, cleaned of untracked files and has its
    /// submodules updated; ignored files (checkpoints upstream code downloaded) stay. Anything else (missing,
    /// not a repo, corrupt, another remote, a half-finished install) is cloned fresh into a staging folder and
    /// swapped in.
    func ensureRepo(url: String, commit: String, at repo: URL, git: String, lines: @escaping @Sendable (String) -> Void) async throws {
        let fm = FileManager.default
        func g(_ dir: URL, _ args: [String]) -> ShellCommand { ShellCommand(git, ["-C", dir.path] + args, environment: toolEnvironment) }
        var reuse = false
        if fm.fileExists(atPath: repo.appending(path: ".git").path) {
            let remote = try? await runner.output(g(repo, ["remote", "get-url", "origin"]))
            let healthy = (try? await runner.run(g(repo, ["status", "--porcelain"]), onLine: { _ in })) == 0
            reuse = healthy && remote?.trimmingCharacters(in: .whitespacesAndNewlines) == url
        }
        if reuse {
            try await logged(g(repo, ["fetch", "--quiet", "--force", "origin"]), lines)
            if (try? await runner.run(g(repo, ["cat-file", "-e", "\(commit)^{commit}"]), onLine: { _ in })) != 0 {
                try await logged(g(repo, ["fetch", "--quiet", "origin", commit]), lines)  // a pin off every branch
            }
            try await logged(g(repo, ["checkout", "--quiet", "--force", commit]), lines)
            try await logged(g(repo, ["clean", "-ffd", "--quiet"]), lines)
            try await logged(g(repo, ["submodule", "update", "--init", "--recursive", "--force", "--quiet"]), lines)
            return
        }
        let staging = repo.deletingLastPathComponent().appending(path: ".repo-staging")
        try? fm.removeItem(at: staging)  // Lift's own leftover
        try await logged(ShellCommand(git, ["clone", "--filter=blob:none", url, staging.path], environment: toolEnvironment), lines)
        try await logged(g(staging, ["checkout", "--quiet", commit]), lines)
        try await logged(g(staging, ["submodule", "update", "--init", "--recursive", "--quiet"]), lines)
        if fm.fileExists(atPath: repo.path) { try fm.removeItem(at: repo) }  // Lift's own working copy
        try fm.moveItem(at: staging, to: repo)
    }

    /// The JSON argument for `python -m lift_worker`.
    public func workerConfig(_ recipe: Recipe, heartbeat: Double) -> String {
        struct Config: Encodable {
            var launcher: String
            var repo_dir: String
            var recipe_dir: String
            var stages: [Recipe.StagePattern]
            var heartbeat_seconds: Double
            var setting_types: [String: [String: String]]
        }
        let config = Config(launcher: installedRecipeDir(recipe.id).appending(path: "launcher.py").path,
                            repo_dir: dir(recipe.id).appending(path: "repo").path,
                            recipe_dir: installedRecipeDir(recipe.id).path,
                            stages: recipe.stages, heartbeat_seconds: heartbeat,
                            setting_types: Dictionary(uniqueKeysWithValues: recipe.tasks.map { task in
                                (task.id, Dictionary(uniqueKeysWithValues: task.settings.map { ($0.key, $0.type.rawValue) }))
                            }))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(config), as: UTF8.self)
    }

    /// Environment for a worker or the smoke check: lift_worker on PYTHONPATH, the venv first on PATH,
    /// `LIFT_SHIM` when the recipe uses the shim, native brew's `lib/` for `brew:` packages, the
    /// Hugging Face cache and token.
    public func workerEnvironment(_ recipe: Recipe) -> [String: String] {
        let venv = dir(recipe.id).appending(path: "venv").path
        var env = toolEnvironment
        env["PATH"] = "\(venv)/bin:" + (toolEnvironment["PATH"] ?? "/usr/bin:/bin")
        env["VIRTUAL_ENV"] = venv
        env["PYTHONPATH"] = workerRuntime.path
        env["PYTHONUNBUFFERED"] = "1"
        if let shim = try? String(contentsOf: shimURL(recipe.id), encoding: .utf8) { env["LIFT_SHIM"] = shim }
        // dyld's default fallback includes /usr/local/lib, where a Rosetta Homebrew keeps x86_64 libraries.
        if !recipe.brew.isEmpty, let prefix = brewPrefix { env["DYLD_FALLBACK_LIBRARY_PATH"] = "\(prefix)/lib:/usr/lib" }
        env["HF_HUB_CACHE"] = hfHub.path
        if let token = hfToken() { env["HF_TOKEN"] = token }
        return env
    }

    /// `hf download <repo> --revision <rev>` for each weight, from the model's venv into the shared cache.
    /// Appends to `install.log`. Only ever started by an explicit user action (spec §6).
    public func downloadWeights(_ recipe: Recipe, onLine: @escaping @Sendable (String) -> Void) async throws {
        for w in recipe.downloadOrder { try await downloadWeight(recipe, w, onLine: onLine) }
    }

    /// `hf download` for one weight, in its own process group so a pause stops all of it. Run again, it picks
    /// up from the `.incomplete` files in the cache.
    public func downloadWeight(_ recipe: Recipe, _ w: Recipe.Weight, onLine: @escaping @Sendable (String) -> Void) async throws {
        let hf = dir(recipe.id).appending(path: "venv/bin/hf").path
        guard FileManager.default.isExecutableFile(atPath: hf) else {
            throw LiftError.prerequisite("\(recipe.id)'s venv has no `hf` (huggingface_hub); add it to the recipe's install steps")
        }
        if recipe.weights.contains(where: \.gated) && hfToken() == nil {
            throw LiftError.prerequisite("\(recipe.name) has gated weights; set a Hugging Face token first")
        }
        let log = try LogFile(logURL(recipe.id))
        let lines: @Sendable (String) -> Void = { line in
            log.write(line)
            onLine(line)
        }
        // Not the worker environment: no LIFT_SHIM or PYTHONPATH for a tool (M1).
        let venv = dir(recipe.id).appending(path: "venv").path
        var env = toolEnvironment
        env["PATH"] = "\(venv)/bin:" + (toolEnvironment["PATH"] ?? "/usr/bin:/bin")
        env["VIRTUAL_ENV"] = venv
        env["HF_HUB_CACHE"] = hfHub.path
        // Plain HTTP: files grow on disk (the progress bar), a rerun resumes from them, little memory. hf_xet held
        // ~1 GB per file in memory, wrote in bursts and lost it all on a pause or relaunch (first real run).
        env["HF_HUB_DISABLE_XET"] = "1"
        if let token = hfToken() { env["HF_TOKEN"] = token }
        let command = ShellCommand(hf, ["download", w.repo] + (w.files ?? []) + ["--revision", w.revision], environment: env, ownProcessGroup: true)
        lines("$ \(command.display)")
        try await runner.check(command, onLine: lines)
    }

    /// Removes `models/<id>/` — Lift's own folder. Weights in the shared Hugging Face cache are never deleted.
    public func uninstall(_ id: String) throws {
        try? FileManager.default.removeItem(at: dir(id))
    }

    /// `git ls-remote` for upstream HEAD; when installed, also fetch and count commits past the pin.
    public func checkUpstream(_ recipe: Recipe, pin: String?) async throws -> UpstreamStatus {
        guard let url = recipe.repo, let git = tools.git else { throw LiftError.invalidState("\(recipe.id) has no upstream repo") }
        let head = try await runner.output(ShellCommand(git, ["ls-remote", url, "HEAD"], environment: toolEnvironment))
            .split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let pin = pin ?? recipe.commit
        let repo = dir(recipe.id).appending(path: "repo").path
        guard readState(recipe.id)?.installed == true, let pin, FileManager.default.fileExists(atPath: repo) else {
            return UpstreamStatus(pin: pin, head: head, commitsAhead: nil)
        }
        try await runner.check(ShellCommand(git, ["-C", repo, "fetch", "--quiet", "origin", head], environment: toolEnvironment))
        let count = try await runner.output(ShellCommand(git, ["-C", repo, "rev-list", "--count", "\(pin)..\(head)"], environment: toolEnvironment))
        return UpstreamStatus(pin: pin, head: head, commitsAhead: Int(count.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}
