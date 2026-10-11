import Foundation

/// Absolute paths of the tools Lift drives. `nil` means not found or not working.
public struct ToolPaths: Codable, Sendable, Equatable {
    /// Native arm64 Homebrew, only when `brew --version` and `brew config` both check out.
    public var brew: String?
    public var git: String?
    /// Some models keep files in Git LFS (UniRig); Lift's own git runs it, whatever the user's git config says.
    public var gitLfs: String?
    public var uv: String?
    /// An Intel/Rosetta Homebrew (`/usr/local/bin/brew`). Reported, never used: its libraries are x86_64.
    public var rosettaBrew: String?

    public init(brew: String? = nil, git: String? = nil, gitLfs: String? = nil, uv: String? = nil, rosettaBrew: String? = nil) {
        self.brew = brew
        self.git = git
        self.gitLfs = gitLfs
        self.uv = uv
        self.rosettaBrew = rosettaBrew
    }
}

public struct Prereqs: Codable, Sendable, Equatable {
    public var tools: ToolPaths
    /// Checked only when asked for (a recipe needs it): `nil` means not checked.
    public var metalToolchain: Bool?

    public init(tools: ToolPaths, metalToolchain: Bool?) {
        self.tools = tools
        self.metalToolchain = metalToolchain
    }

    /// Native brew, git, git-lfs or uv not working, or the Metal Toolchain checked and absent.
    public var missing: Bool { tools.brew == nil || tools.git == nil || tools.gitLfs == nil || tools.uv == nil || metalToolchain == false }
}

/// Finds and installs native Homebrew / git / uv / the Metal Toolchain (spec §6).
/// A GUI app's PATH is minimal, so tools are looked up in fixed directories. The Rosetta prefix
/// (`/usr/local`) is never searched: an x86_64 uv would build x86_64 venvs.
public struct Toolchain: Sendable {
    public static let brewRepo = "https://github.com/Homebrew/brew"

    let runner: any CommandRunner
    let searchDirs: [String]
    public let homebrewPrefix: String
    let rosettaPrefix: String
    let userName: String

    public init(runner: any CommandRunner, searchDirs: [String]? = nil, homebrewPrefix: String = "/opt/homebrew", rosettaPrefix: String = "/usr/local",
                userName: String = NSUserName()) {
        self.runner = runner
        self.userName = userName
        self.homebrewPrefix = homebrewPrefix
        self.rosettaPrefix = rosettaPrefix
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fromPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
            .filter { !$0.hasPrefix(rosettaPrefix) }
        var seen = Set<String>()
        self.searchDirs = (searchDirs ?? (["\(homebrewPrefix)/bin", "\(home)/.local/bin", "\(home)/.cargo/bin"] + fromPath + ["/usr/bin", "/bin"]))
            .filter { seen.insert($0).inserted }
    }

    public func find(_ name: String) -> String? {
        searchDirs.lazy.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func works(_ executable: String, _ arguments: [String] = ["--version"]) async -> Bool {
        (try? await runner.run(ShellCommand(executable, arguments), onLine: { _ in })) == 0
    }

    /// `<prefix>/bin/brew`, if it runs and `brew config` reports this prefix on arm64.
    /// An empty or partial `/opt/homebrew` counts as missing.
    public func nativeBrew() async -> String? {
        let brew = "\(homebrewPrefix)/bin/brew"
        guard FileManager.default.isExecutableFile(atPath: brew), await works(brew),
              let config = try? await runner.output(ShellCommand(brew, ["config"])),
              config.contains("HOMEBREW_PREFIX: \(homebrewPrefix)"), config.contains("arm64") else { return nil }
        return brew
    }

    /// Each tool counts only if it runs. `/usr/bin/git` is a stub that pops up an installer dialog
    /// without the Command Line Tools, so it's only tried when `xcode-select -p` succeeds.
    public func detect() async -> ToolPaths {
        var git = find("git")
        if git == "/usr/bin/git", !(await works("/usr/bin/xcode-select", ["-p"])) { git = nil }
        if let g = git, !(await works(g)) { git = nil }
        var gitLfs = find("git-lfs")
        if let l = gitLfs, !(await works(l, ["version"])) { gitLfs = nil }
        var uv = find("uv")
        if let u = uv, !(await works(u)) { uv = nil }
        let rosetta = "\(rosettaPrefix)/bin/brew"
        return ToolPaths(brew: await nativeBrew(), git: git, gitLfs: gitLfs, uv: uv,
                         rosettaBrew: FileManager.default.isExecutableFile(atPath: rosetta) ? rosetta : nil)
    }

    /// PATH for child processes: the search directories, so `uv` and `git` resolve inside install steps.
    public var environment: [String: String] {
        // GIT_TERMINAL_PROMPT=0: a GUI app has no terminal; a repo needing credentials fails instead of hanging.
        // No user or system git config: an LFS filter there (with git-lfs off this PATH) broke UniRig's checkout.
        // Lift's own LFS filter instead, through git's GIT_CONFIG_* variables, when setup has git-lfs.
        var env = ["PATH": searchDirs.joined(separator: ":"), "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]
        if let lfs = find("git-lfs") {
            let config = [("filter.lfs.process", "\(lfs) filter-process"), ("filter.lfs.smudge", "\(lfs) smudge -- %f"),
                          ("filter.lfs.clean", "\(lfs) clean -- %f"), ("filter.lfs.required", "true")]
            env["GIT_CONFIG_COUNT"] = "\(config.count)"
            for (i, (key, value)) in config.enumerated() { env["GIT_CONFIG_KEY_\(i)"] = key; env["GIT_CONFIG_VALUE_\(i)"] = value }
        }
        return env
    }

    public func metalToolchainInstalled() async -> Bool {
        await works("/usr/bin/xcrun", ["metal", "--version"])
    }

    /// The GUI-safe native install (spec §6). Homebrew's own installer refuses root and needs a terminal
    /// for sudo, so: one administrator dialog creates the prefix and gives it to the user, then, as the user,
    /// Homebrew `main` is fetched into it (like the official installer: files already there are
    /// overwritten by Homebrew's own, nothing is deleted) and `brew update` runs.
    public func installHomebrew(git: String, onLine: @escaping @Sendable (String) -> Void) async throws {
        let p = homebrewPrefix
        // AppleScript's `quoted form of` shell-quotes the values, whatever they contain (M16).
        func q(_ s: String) -> String { "quoted form of \"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let script = "do shell script \"/bin/mkdir -p \" & \(q(p)) & \" && /usr/sbin/chown -R \" & \(q(userName + ":admin")) & \" \" & \(q(p)) with administrator privileges"
        try await runner.check(ShellCommand("/usr/bin/osascript", ["-e", script]), onLine: onLine)
        for args in [["init", "-q"], ["config", "remote.origin.url", Self.brewRepo],
                     ["config", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"],
                     ["fetch", "--force", "--quiet", "origin"], ["checkout", "--force", "-B", "main", "origin/main"]] {
            try await runner.check(ShellCommand(git, ["-C", p] + args, environment: environment), onLine: onLine)
        }
        try await runner.check(ShellCommand("\(p)/bin/brew", ["update", "--force", "--quiet"], environment: environment), onLine: onLine)
    }

    /// `brew install <names>` with the native brew only.
    public func brewInstall(_ names: [String], onLine: @escaping @Sendable (String) -> Void) async throws {
        guard let brew = await nativeBrew() else { throw LiftError.prerequisite("native Homebrew (\(homebrewPrefix)) is not installed") }
        try await runner.check(ShellCommand(brew, ["install"] + names, environment: environment), onLine: onLine)
    }

    public func installMetalToolchain(onLine: @escaping @Sendable (String) -> Void) async throws {
        try await runner.check(ShellCommand("/usr/bin/xcodebuild", ["-downloadComponent", "MetalToolchain"]), onLine: onLine)
    }
}
