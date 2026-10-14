import CryptoKit
import Foundation
import LiftCore
import Observation

/// An AI assistant Lift can connect to its MCP endpoint with one click (Settings → AI assistants, setup's last step).
/// Only ever from a click: these change the user's own assistant settings, so nothing here is exposed over MCP or HTTP.
/// Always over HTTP, never stdio (so not Claude Desktop, whose settings file only starts programs).
public enum Assistant: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, codex
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    public var blurb: String {
        switch self {
        case .claudeCode: "Use Lift from Claude Code in your terminal"
        case .codex: "Use Lift from OpenAI's Codex in your terminal"
        }
    }

    /// Where to get it, for "Not installed".
    public var download: URL {
        switch self {
        case .claudeCode: URL(string: "https://claude.com/product/claude-code")!
        case .codex: URL(string: "https://developers.openai.com/codex/cli")!
        }
    }
}

public enum AssistantState: Equatable, Sendable {
    case notInstalled, notConnected, connected
    /// Lift's own entry, pointing at an old port or an old copy of the app.
    case needsUpdate
    /// Something else is already set up under the name "lift": replaced only after asking.
    case taken
}

/// Lift's skill for an assistant (`<skills>/lift/SKILL.md`, with `.installed-by-lift` holding its SHA-256).
public enum SkillState: Equatable, Sendable {
    case missing, installed
    /// Ours and unedited, but this Lift ships a newer one.
    case outdated
    /// Ours, but the user changed it: kept as it is.
    case edited
    /// A "lift" skill Lift didn't install: never touched.
    case foreign
}

public enum AssistantError: Error, Equatable, CustomStringConvertible {
    case taken(Assistant)
    case notInstalled(Assistant)
    /// Its `codex mcp add` has no `--url`, so it can't connect over HTTP.
    case codexTooOld

    public var description: String {
        switch self {
        case .taken(let a): "\(a.name) already has a different tool called “lift”. Lift left it alone."
        case .notInstalled(let a): "\(a.name) isn't installed on this Mac."
        case .codexTooOld: "This version of Codex can't connect over HTTP. Update it (npm install -g @openai/codex@latest), then click Connect."
        }
    }
}

extension AssistantError: LocalizedError {
    public var errorDescription: String? { description }
}

/// What an assistant's "lift" entry points at.
struct AssistantEntry: Equatable {
    var url: String?
    var command: String?
    var args: [String] = []
    /// `claude mcp remove` scope, from `claude mcp get`.
    var scope: String?

    /// The MCP address: the HTTP URL, or the `--url` of the stdio bridge older Lifts set up.
    var liftURL: String? {
        url ?? args.firstIndex(of: "--url").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    /// Lift's own: the old stdio bridge (replaced on Update), or an address on this Mac ending in /mcp.
    var isLifts: Bool {
        if let command, URL(filePath: command).lastPathComponent == "lift-mcp" { return true }
        guard let u = liftURL.flatMap(URLComponents.init(string:)) else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(u.host ?? "") && u.path == "/mcp"
    }
}

/// Detects, connects and disconnects each assistant. Everything goes through `runner` and files under `home`,
/// so tests use a fake runner and a temp folder.
public struct AssistantConnector: Sendable {
    public var mcpURL: String
    /// The SKILL.md this Lift ships (nil: no skill to install).
    public var skill: String?
    let runner: any CommandRunner
    let home: URL
    /// Where to look for `claude` and `codex` after the login shell's PATH.
    let searchDirs: [String]

    public init(mcpURL: String, skill: String? = nil, runner: any CommandRunner = SubprocessRunner(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser, searchDirs: [String]? = nil) {
        self.mcpURL = mcpURL
        self.skill = skill
        self.runner = runner
        self.home = home
        self.searchDirs = searchDirs ?? [".local/bin", ".claude/local", ".npm-global/bin", ".volta/bin", ".bun/bin"].map { home.appending(path: $0).path }
            + ["/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// The commands (or settings) for doing it by hand, under Show details.
    public func snippet(_ a: Assistant) -> String {
        switch a {
        case .claudeCode: "claude mcp add --scope user --transport http lift \(mcpURL)"
        case .codex: "codex mcp add lift --url \(mcpURL)"
        }
    }

    // MARK: the skill

    /// `~/.claude/skills/lift` or `~/.codex/skills/lift`.
    func skillDir(_ a: Assistant) -> URL {
        switch a {
        case .claudeCode: home.appending(path: ".claude/skills/lift")
        case .codex: home.appending(path: ".codex/skills/lift")
        }
    }

    public func skillState(_ a: Assistant) -> SkillState {
        let dir = skillDir(a)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return .missing }
        guard let marker = fm.contents(atPath: dir.appending(path: ".installed-by-lift").path) else { return .foreign }
        let wrote = String(decoding: marker, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = fm.contents(atPath: dir.appending(path: "SKILL.md").path), Self.sha256(current) == wrote else { return .edited }
        return skill.map { Self.sha256(Data($0.utf8)) == wrote } == false ? .outdated : .installed
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Installs or updates Lift's skill, unless it's someone else's or the user edited it. Returns a note for those.
    @discardableResult
    func installSkill(_ a: Assistant) throws -> String? {
        guard let skill else { return nil }
        let dir = skillDir(a)
        switch skillState(a) {
        case .foreign: return "A different “lift” skill is already installed, so Lift left it alone."
        case .edited: return "You changed Lift's skill, so Lift kept your version."
        case .installed: return nil
        case .missing, .outdated:
            let data = Data(skill.utf8)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appending(path: "SKILL.md"), options: .atomic)
            try Data(Self.sha256(data).utf8).write(to: dir.appending(path: ".installed-by-lift"), options: .atomic)
            return nil
        }
    }

    /// Removes the two files Lift wrote, and the folder only if nothing else is in it. Returns a note when it kept it.
    @discardableResult
    func removeSkill(_ a: Assistant) throws -> String? {
        let dir = skillDir(a)
        switch skillState(a) {
        case .edited: return "You changed Lift's skill, so Lift left it in place."
        case .foreign, .missing: return nil
        case .installed, .outdated:
            let fm = FileManager.default
            try fm.removeItem(at: dir.appending(path: "SKILL.md"))
            try fm.removeItem(at: dir.appending(path: ".installed-by-lift"))
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try fm.removeItem(at: dir) }
            return nil
        }
    }

    // MARK: detect

    public func detect(_ a: Assistant) async -> AssistantState {
        guard let cli = await find(a) else { return .notInstalled }
        return state(await entry(a, cli: cli))
    }

    func state(_ entry: AssistantEntry?) -> AssistantState {
        guard let entry else { return .notConnected }
        guard entry.isLifts else { return .taken }
        // An old stdio-bridge entry is Lift's but not HTTP: Update replaces it with the URL.
        return entry.command == nil && entry.liftURL == mcpURL ? .connected : .needsUpdate
    }

    // MARK: connect / disconnect

    /// Connects, or updates Lift's own old entry. A "lift" that isn't Lift's is replaced only with `replacing`.
    /// Returns a note to show afterwards, if any.
    @discardableResult
    public func connect(_ a: Assistant, replacing: Bool = false) async throws -> String? {
        guard let cli = await find(a) else { throw AssistantError.notInstalled(a) }
        let existing = await entry(a, cli: cli)
        if let existing, !existing.isLifts, !replacing { throw AssistantError.taken(a) }
        // Worked out before anything is removed, so a refusal leaves the old entry in place.
        let add: [String]
        if a == .claudeCode {
            add = ["mcp", "add", "--scope", "user", "--transport", "http", "lift", mcpURL]
        } else if ((try? await runner.output(command(cli, ["mcp", "add", "--help"]))) ?? "").contains("--url") {
            add = ["mcp", "add", "lift", "--url", mcpURL]
        } else {
            throw AssistantError.codexTooOld  // it only starts programs (stdio), which Lift never uses
        }
        if existing != nil { try await disconnect(a, cli: cli, existing: existing) }
        try await run(cli, add)
        return try installSkill(a)
    }

    /// Removes the MCP entry, then Lift's skill if it's still as Lift wrote it. Returns a note when the skill stays.
    @discardableResult
    public func disconnect(_ a: Assistant) async throws -> String? {
        guard let cli = await find(a) else { throw AssistantError.notInstalled(a) }
        try await disconnect(a, cli: cli, existing: a == .claudeCode ? await entry(a, cli: cli) : nil)
        return try removeSkill(a)
    }

    func disconnect(_ a: Assistant, cli: String, existing: AssistantEntry?) async throws {
        switch a {
        case .claudeCode: try await run(cli, ["mcp", "remove", "--scope", existing?.scope ?? "user", "lift"])
        case .codex: try await run(cli, ["mcp", "remove", "lift"])
        }
    }

    // MARK: the CLIs

    /// The login shell's PATH first (where Terminal finds it), then the usual install spots.
    func find(_ a: Assistant) async -> String? {
        let tool = a == .codex ? "codex" : "claude"
        let fm = FileManager.default
        let shell = try? await runner.output(ShellCommand("/bin/zsh", ["-lc", "command -v \(tool)"]))
        if let path = shell?.split(separator: "\n").last.map(String.init), path.hasPrefix("/"), fm.isExecutableFile(atPath: path) { return path }
        return searchDirs.map { "\($0)/\(tool)" }.first { fm.isExecutableFile(atPath: $0) }
    }

    /// The CLI's own folder leads PATH, so an npm install finds the `node` next to it.
    func command(_ cli: String, _ args: [String]) -> ShellCommand {
        let dir = URL(filePath: cli).deletingLastPathComponent().path
        return ShellCommand(cli, args, environment: ["HOME": home.path, "PATH": "\(dir):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"],
                            workingDirectory: home.path)
    }

    func run(_ cli: String, _ args: [String]) async throws {
        try await runner.check(command(cli, args))
    }

    func entry(_ a: Assistant, cli: String) async -> AssistantEntry? {
        switch a {
        case .claudeCode:
            guard let out = try? await runner.output(command(cli, ["mcp", "get", "lift"])) else { return nil }
            return Self.parseClaude(out)
        case .codex:
            guard let out = try? await runner.output(command(cli, ["mcp", "get", "lift", "--json"])) else { return nil }
            return Self.parseCodex(out)
        }
    }

    /// `claude mcp get lift`: "  URL: …", or "  Command: …" and "  Args: …", and the remove hint's `-s <scope>`.
    static func parseClaude(_ out: String) -> AssistantEntry {
        var e = AssistantEntry()
        for raw in out.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            func value(_ key: String) -> String? {
                line.hasPrefix(key) ? line.dropFirst(key.count).trimmingCharacters(in: .whitespaces) : nil
            }
            if let v = value("URL:") { e.url = v }
            if let v = value("Command:") { e.command = v }
            if let v = value("Args:") { e.args = v.split(separator: " ").map(String.init) }
            if let v = value("Scope:") { e.scope = e.scope ?? (v.hasPrefix("Local") ? "local" : v.hasPrefix("Project") ? "project" : "user") }
            if line.hasPrefix("To remove"), let r = line.range(of: " -s ") { e.scope = line[r.upperBound...].split(separator: " ").first.map(String.init) }
        }
        return e
    }

    /// `codex mcp get lift --json`: `{"transport": {"type", "url" | "command", "args"}}`.
    static func parseCodex(_ out: String) -> AssistantEntry? {
        guard let json = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any] else { return nil }
        let t = json["transport"] as? [String: Any] ?? json
        return AssistantEntry(url: t["url"] as? String, command: t["command"] as? String, args: t["args"] as? [String] ?? [])
    }
}

/// Each assistant's row for Settings and setup: where it stands, and what the last click did.
@MainActor @Observable
public final class AssistantsModel {
    public struct Row: Equatable, Sendable {
        public var state: AssistantState?
        public var busy = false
        /// After a success, e.g. "Restart Claude to finish connecting."
        public var note: String?
        /// A plain one-line error, and the command's output for Show details.
        public var failure: String?
        public var details: String?
        /// nil until checked.
        public var skill: SkillState?
    }

    public private(set) var rows: [Assistant: Row] = [:]
    public private(set) var connector: AssistantConnector?
    /// Builds the connector for Lift's MCP address. The app sets it; without it nothing is checked or
    /// run, so unit tests and the launch smoke test never start a real `claude` or `codex`.
    public var makeConnector: (@MainActor (_ mcpURL: String, _ skill: String?) -> AssistantConnector)?

    public init() {}

    /// Connected to an old address (Lift's port changed): each gets an Update button, never a silent fix.
    public var needingUpdate: [Assistant] { Assistant.allCases.filter { rows[$0]?.state == .needsUpdate } }

    /// Detects both at once (`claude mcp get` health-checks, so it can take a few seconds).
    /// Also brings an unedited skill up to this Lift's version for each connected assistant (Lift was updated).
    public func check(mcpURL: String?, skill: String? = nil) async {
        guard let mcpURL, let makeConnector else { return }
        let c = makeConnector(mcpURL, skill)
        connector = c
        async let code = c.detect(.claudeCode), codex = c.detect(.codex)
        for (a, state) in [(Assistant.claudeCode, await code), (.codex, await codex)] {
            if state != .notInstalled, state != .notConnected, state != .taken, c.skillState(a) == .outdated { _ = try? c.installSkill(a) }
            rows[a, default: Row()].state = state
            rows[a]?.skill = c.skillState(a)
        }
    }

    /// Connect, Update, or (with `replacing`, after the user said yes) Replace.
    public func connect(_ a: Assistant, replacing: Bool = false) async {
        await act(a, "connect") { try await $0.connect(a, replacing: replacing) }
    }

    public func disconnect(_ a: Assistant) async {
        await act(a, "disconnect") { try await $0.disconnect(a) }
    }

    func act(_ a: Assistant, _ verb: String, _ body: @escaping @Sendable (AssistantConnector) async throws -> String?) async {
        guard let c = connector, rows[a]?.busy != true else { return }
        rows[a, default: Row()] = Row(state: rows[a]?.state, busy: true)
        var row = Row()
        do {
            row.note = try await body(c)
        } catch let e as AssistantError {
            row.failure = e.description
        } catch {
            row.failure = "Lift couldn't \(verb) \(a.name)."
            row.details = Format.error(error)
        }
        row.state = await c.detect(a)
        row.skill = c.skillState(a)
        rows[a] = row
    }
}
