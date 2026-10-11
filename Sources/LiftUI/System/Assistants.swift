import CryptoKit
import Foundation
import LiftCore
import Observation

/// An AI assistant Lift can connect to its MCP endpoint with one click (Settings → AI assistants, setup's last step).
/// Only ever from a click: these change the user's own assistant settings, so nothing here is exposed over MCP or HTTP.
public enum Assistant: String, CaseIterable, Identifiable, Sendable {
    case claudeCode, claudeDesktop, codex
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .claudeDesktop: "Claude Desktop"
        case .codex: "Codex"
        }
    }

    public var blurb: String {
        switch self {
        case .claudeCode: "Use Lift from Claude Code in your terminal"
        case .claudeDesktop: "Use Lift from the Claude app"
        case .codex: "Use Lift from OpenAI's Codex in your terminal"
        }
    }

    /// Where to get it, for "Not installed".
    public var download: URL {
        switch self {
        case .claudeCode: URL(string: "https://claude.com/product/claude-code")!
        case .claudeDesktop: URL(string: "https://claude.ai/download")!
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
    case noBridge
    case badSettings(String)

    public var description: String {
        switch self {
        case .taken(let a): "\(a.name) already has a different tool called “lift”. Lift left it alone."
        case .notInstalled(let a): "\(a.name) isn't installed on this Mac."
        case .noBridge: "This copy of Lift doesn't include its connector program (lift-mcp), so it can't connect this assistant."
        case .badSettings(let why): "Claude's settings file couldn't be read, so Lift left it alone. \(why)"
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

    /// The MCP address: the HTTP URL, or the bridge's `--url`.
    var liftURL: String? {
        url ?? args.firstIndex(of: "--url").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
    }

    /// Lift's own: the bridge, or an address on this Mac ending in /mcp.
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
    /// The `lift-mcp` inside the running app bundle.
    public var bridge: String?
    /// The SKILL.md this Lift ships (nil: no skill to install).
    public var skill: String?
    let runner: any CommandRunner
    let home: URL
    /// Where to look for `claude` and `codex` after the login shell's PATH.
    let searchDirs: [String]
    /// Where Claude.app may be.
    let applications: [URL]

    public init(mcpURL: String, bridge: String?, skill: String? = nil, runner: any CommandRunner = SubprocessRunner(),
                home: URL = FileManager.default.homeDirectoryForCurrentUser, searchDirs: [String]? = nil, applications: [URL]? = nil) {
        self.mcpURL = mcpURL
        self.bridge = bridge
        self.skill = skill
        self.runner = runner
        self.home = home
        self.searchDirs = searchDirs ?? [".local/bin", ".claude/local", ".npm-global/bin", ".volta/bin", ".bun/bin"].map { home.appending(path: $0).path }
            + ["/opt/homebrew/bin", "/usr/local/bin"]
        self.applications = applications ?? [URL(filePath: "/Applications/Claude.app"), home.appending(path: "Applications/Claude.app")]
    }

    var desktopConfig: URL { home.appending(path: "Library/Application Support/Claude/claude_desktop_config.json") }

    /// The commands (or settings) for doing it by hand, under Show details.
    public func snippet(_ a: Assistant) -> String {
        switch a {
        case .claudeCode: "claude mcp add --scope user --transport http lift \(mcpURL)"
        case .codex: "codex mcp add lift --url \(mcpURL)"
        case .claudeDesktop: "\"lift\": " + JSONText.render(desktopValue, indent: "", step: "  ", multiline: true)
        }
    }

    // MARK: the skill

    /// `~/.claude/skills/lift` or `~/.codex/skills/lift`; Claude Desktop has no skills folder.
    func skillDir(_ a: Assistant) -> URL? {
        switch a {
        case .claudeCode: home.appending(path: ".claude/skills/lift")
        case .codex: home.appending(path: ".codex/skills/lift")
        case .claudeDesktop: nil
        }
    }

    public func skillState(_ a: Assistant) -> SkillState? {
        guard let dir = skillDir(a) else { return nil }
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
        guard let dir = skillDir(a), let skill else { return nil }
        switch skillState(a) {
        case .foreign: return "A different “lift” skill is already installed, so Lift left it alone."
        case .edited: return "You changed Lift's skill, so Lift kept your version."
        case .installed, nil: return nil
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
        guard let dir = skillDir(a) else { return nil }
        switch skillState(a) {
        case .edited: return "You changed Lift's skill, so Lift left it in place."
        case .foreign, .missing, nil: return nil
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
        switch a {
        case .claudeCode, .codex:
            guard let cli = await find(a) else { return .notInstalled }
            return state(await entry(a, cli: cli))
        case .claudeDesktop:
            let fm = FileManager.default
            guard fm.fileExists(atPath: desktopConfig.path) || applications.contains(where: { fm.fileExists(atPath: $0.path) }) else {
                return .notInstalled
            }
            return state((try? readDesktop())?.entry)
        }
    }

    func state(_ entry: AssistantEntry?) -> AssistantState {
        guard let entry else { return .notConnected }
        guard entry.isLifts else { return .taken }
        let sameBridge = entry.command == nil || bridge == nil || entry.command == bridge
        return entry.liftURL == mcpURL && sameBridge ? .connected : .needsUpdate
    }

    // MARK: connect / disconnect

    /// Connects, or updates Lift's own old entry. A "lift" that isn't Lift's is replaced only with `replacing`.
    /// Returns a note to show afterwards, if any.
    @discardableResult
    public func connect(_ a: Assistant, replacing: Bool = false) async throws -> String? {
        if a == .claudeDesktop {
            try editDesktop { existing in
                if let existing, !existing.isLifts, !replacing { throw AssistantError.taken(a) }
                return desktopValue
            }
            return "Restart Claude to finish connecting."
        }
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
            // Older Codex only starts programs: then it gets the bridge, pointed at the same address.
            guard let bridge else { throw AssistantError.noBridge }
            add = ["mcp", "add", "lift", "--", bridge, "--url", mcpURL]
        }
        if existing != nil { try await disconnect(a, cli: cli, existing: existing) }
        try await run(cli, add)
        return try installSkill(a)
    }

    /// Removes the MCP entry, then Lift's skill if it's still as Lift wrote it. Returns a note when the skill stays.
    @discardableResult
    public func disconnect(_ a: Assistant) async throws -> String? {
        if a == .claudeDesktop { try editDesktop { _ in nil }; return nil }
        guard let cli = await find(a) else { throw AssistantError.notInstalled(a) }
        try await disconnect(a, cli: cli, existing: a == .claudeCode ? await entry(a, cli: cli) : nil)
        return try removeSkill(a)
    }

    func disconnect(_ a: Assistant, cli: String, existing: AssistantEntry?) async throws {
        switch a {
        case .claudeCode: try await run(cli, ["mcp", "remove", "--scope", existing?.scope ?? "user", "lift"])
        case .codex: try await run(cli, ["mcp", "remove", "lift"])
        case .claudeDesktop: break
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
        case .claudeDesktop: return nil
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

    // MARK: Claude Desktop's settings file

    var desktopValue: JSONText.Value {
        .object([("command", .string(bridge ?? "lift-mcp")), ("args", .array([.string("--url"), .string(mcpURL)]))])
    }

    /// The file's text and its `mcpServers.lift`, or nil when there's no file yet.
    func readDesktop() throws -> (text: [UInt8], entry: AssistantEntry?)? {
        guard let data = FileManager.default.contents(atPath: desktopConfig.path) else { return nil }
        let bytes = [UInt8](data)
        if bytes.allSatisfy(JSONText.isSpace) { return (Array("{}\n".utf8), nil) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssistantError.badSettings("It isn't valid JSON. Fix or remove \(desktopConfig.path), then try again.")
        }
        guard json["mcpServers"] == nil || json["mcpServers"] is [String: Any] else {
            throw AssistantError.badSettings("Its “mcpServers” isn't a list of servers.")
        }
        guard let lift = (json["mcpServers"] as? [String: Any])?["lift"] else { return (bytes, nil) }
        let o = lift as? [String: Any] ?? [:]
        return (bytes, AssistantEntry(url: o["url"] as? String, command: o["command"] as? String, args: o["args"] as? [String] ?? []))
    }

    /// Sets (or with nil removes) `mcpServers.lift`, changing no other byte. Keeps a one-time backup of the
    /// original next to it, then writes atomically. Without a bridge it refuses, before touching anything.
    func editDesktop(_ change: (AssistantEntry?) throws -> JSONText.Value?) throws {
        let current = try readDesktop()
        guard let value = try change(current?.entry) else {
            guard let current, current.entry != nil else { return }
            return try write(JSONText.removing("lift", in: "mcpServers", current.text), original: true)
        }
        if bridge == nil { throw AssistantError.noBridge }
        try write(try JSONText.setting("lift", to: value, in: "mcpServers", current?.text ?? Array("{}\n".utf8)), original: current != nil)
    }

    func write(_ bytes: [UInt8], original: Bool) throws {
        let fm = FileManager.default
        let target = desktopConfig.resolvingSymlinksInPath()  // a symlinked settings file stays a symlink
        let backup = URL(filePath: desktopConfig.path + ".lift-backup")
        if original, !fm.fileExists(atPath: backup.path) { try fm.copyItem(at: target, to: backup) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: target, options: .atomic)
    }
}

/// Edits one member of a JSON object in the text itself, so every other byte (order, spacing, number spellings,
/// escapes) stays exactly as it was. The text must already be valid JSON (checked by the caller).
enum JSONText {
    indirect enum Value {
        case string(String)
        case array([Value])
        case object([(String, Value)])
    }

    struct Member { var key: String; var keyStart: Int; var valueStart: Int; var valueEnd: Int }

    static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D }

    struct Malformed: Error {}

    /// Sets `object.key` (creating `object` in the top level when it's absent).
    static func setting(_ key: String, to value: Value, in object: String, _ b: [UInt8]) throws -> [UInt8] {
        let top = try start(b)
        let (topMembers, _) = try members(b, at: top)
        if let parent = topMembers.first(where: { $0.key == object }) {
            return try set(key, value, inObjectAt: parent.valueStart, b, step: step(b, top, topMembers))
        }
        return try set(object, .object([(key, value)]), inObjectAt: top, b, step: step(b, top, topMembers))
    }

    /// Removes `object.key`, with the comma and spacing that came with it.
    static func removing(_ key: String, in object: String, _ b: [UInt8]) throws -> [UInt8] {
        let (topMembers, _) = try members(b, at: try start(b))
        guard let parent = topMembers.first(where: { $0.key == object }) else { return b }
        let (ms, close) = try members(b, at: parent.valueStart)
        guard let k = ms.firstIndex(where: { $0.key == key }) else { return b }
        let range = ms.count == 1 ? parent.valueStart + 1 ..< close
            : k > 0 ? ms[k - 1].valueEnd ..< ms[k].valueEnd
            : ms[0].keyStart ..< ms[1].keyStart
        var out = b
        out.removeSubrange(range)
        return out
    }

    static func set(_ key: String, _ value: Value, inObjectAt open: Int, _ b: [UInt8], step: String) throws -> [UInt8] {
        let (ms, close) = try members(b, at: open)
        let multiline = b[open...close].contains(0x0A) || ms.isEmpty && b.contains(0x0A)
        var out = b
        if let m = ms.first(where: { $0.key == key }) {
            let indent = lineIndent(b, m.keyStart)
            out.replaceSubrange(m.valueStart ..< m.valueEnd, with: Array(render(value, indent: indent, step: step, multiline: multiline).utf8))
        } else if let last = ms.last {
            let indent = multiline ? lineIndent(b, last.keyStart) : ""
            let text = (multiline ? ",\n" + indent : ", ") + quote(key) + ": " + render(value, indent: indent, step: step, multiline: multiline)
            out.insert(contentsOf: Array(text.utf8), at: last.valueEnd)
        } else {
            let outer = lineIndent(b, open), indent = outer + step
            let member = quote(key) + ": " + render(value, indent: indent, step: step, multiline: multiline)
            out.replaceSubrange(open + 1 ..< close, with: Array((multiline ? "\n" + indent + member + "\n" + outer : member).utf8))
        }
        return out
    }

    /// The file's indent step: its first member's indent beyond the top-level brace's, else two spaces.
    static func step(_ b: [UInt8], _ top: Int, _ ms: [Member]) -> String {
        guard let first = ms.first else { return "  " }
        let inner = lineIndent(b, first.keyStart), outer = lineIndent(b, top)
        return inner.count > outer.count && inner.hasPrefix(outer) ? String(inner.dropFirst(outer.count)) : "  "
    }

    /// The spaces and tabs that start the line holding `pos`.
    static func lineIndent(_ b: [UInt8], _ pos: Int) -> String {
        var s = pos
        while s > 0 && b[s - 1] != 0x0A { s -= 1 }
        var e = s
        while e < b.count && (b[e] == 0x20 || b[e] == 0x09) { e += 1 }
        return String(decoding: b[s..<e], as: UTF8.self)
    }

    static func render(_ v: Value, indent: String, step: String, multiline: Bool) -> String {
        let inner = indent + step
        func items(_ parts: [String], _ open: String, _ close: String) -> String {
            if parts.isEmpty { return open + close }
            return multiline ? open + "\n" + parts.map { inner + $0 }.joined(separator: ",\n") + "\n" + indent + close
                : open + parts.joined(separator: ", ") + close
        }
        switch v {
        case .string(let s): return quote(s)
        case .array(let a): return items(a.map { render($0, indent: inner, step: step, multiline: multiline) }, "[", "]")
        case .object(let o): return items(o.map { quote($0.0) + ": " + render($0.1, indent: inner, step: step, multiline: multiline) }, "{", "}")
        }
    }

    static func quote(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: (try? encoder.encode(s)) ?? Data("\"\"".utf8), as: UTF8.self)
    }

    // MARK: scanning

    static func start(_ b: [UInt8]) throws -> Int {
        var i = 0
        skipSpace(b, &i)
        guard i < b.count, b[i] == UInt8(ascii: "{") else { throw Malformed() }
        return i
    }

    /// The members of the object whose `{` is at `open`, and the index of its `}`.
    static func members(_ b: [UInt8], at open: Int) throws -> ([Member], Int) {
        var i = open + 1, out: [Member] = []
        while true {
            skipSpace(b, &i)
            guard i < b.count else { throw Malformed() }
            if b[i] == UInt8(ascii: "}") { return (out, i) }
            if b[i] == UInt8(ascii: ",") { i += 1; continue }
            let keyStart = i
            let raw = try skipString(b, &i)
            let key = try JSONDecoder().decode(String.self, from: Data(raw))
            skipSpace(b, &i)
            guard i < b.count, b[i] == UInt8(ascii: ":") else { throw Malformed() }
            i += 1
            skipSpace(b, &i)
            let valueStart = i
            try skipValue(b, &i)
            out.append(Member(key: key, keyStart: keyStart, valueStart: valueStart, valueEnd: i))
        }
    }

    static func skipSpace(_ b: [UInt8], _ i: inout Int) {
        while i < b.count && isSpace(b[i]) { i += 1 }
    }

    @discardableResult
    static func skipString(_ b: [UInt8], _ i: inout Int) throws -> ArraySlice<UInt8> {
        guard i < b.count, b[i] == UInt8(ascii: "\"") else { throw Malformed() }
        let s = i
        i += 1
        while i < b.count && b[i] != UInt8(ascii: "\"") { i += b[i] == UInt8(ascii: "\\") ? 2 : 1 }
        guard i < b.count else { throw Malformed() }
        i += 1
        return b[s..<i]
    }

    static func skipValue(_ b: [UInt8], _ i: inout Int) throws {
        guard i < b.count else { throw Malformed() }
        switch b[i] {
        case UInt8(ascii: "\""): try skipString(b, &i)
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            var depth = 0
            repeat {
                guard i < b.count else { throw Malformed() }
                switch b[i] {
                case UInt8(ascii: "\""): try skipString(b, &i); continue
                case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
                case UInt8(ascii: "}"), UInt8(ascii: "]"): depth -= 1
                default: break
                }
                i += 1
            } while depth > 0
        default:
            while i < b.count && !isSpace(b[i]) && ![UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")].contains(b[i]) { i += 1 }
        }
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
        /// nil for Claude Desktop, which has no skills.
        public var skill: SkillState?
    }

    public private(set) var rows: [Assistant: Row] = [:]
    public private(set) var connector: AssistantConnector?
    /// Builds the connector for Lift's MCP address and bridge. The app sets it; without it nothing is checked or
    /// run, so unit tests and the launch smoke test never start a real `claude` or `codex`.
    public var makeConnector: (@MainActor (_ mcpURL: String, _ bridge: String?, _ skill: String?) -> AssistantConnector)?

    public init() {}

    /// Connected to an old address (Lift's port changed): each gets an Update button, never a silent fix.
    public var needingUpdate: [Assistant] { Assistant.allCases.filter { rows[$0]?.state == .needsUpdate } }

    /// Detects all three at once (`claude mcp get` health-checks, so it can take a few seconds).
    /// Also brings an unedited skill up to this Lift's version for each connected assistant (Lift was updated).
    public func check(mcpURL: String?, bridge: String?, skill: String? = nil) async {
        guard let mcpURL, let makeConnector else { return }
        let c = makeConnector(mcpURL, bridge, skill)
        connector = c
        async let code = c.detect(.claudeCode), desktop = c.detect(.claudeDesktop), codex = c.detect(.codex)
        for (a, state) in [(Assistant.claudeCode, await code), (.claudeDesktop, await desktop), (.codex, await codex)] {
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
