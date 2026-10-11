import Foundation
import LiftCore
import LiftServer
import Synchronization
import Testing
@testable import LiftUI

/// Commands go to `Script`, never to a real `claude` or `codex`; HOME is a temp folder, so no test reads or
/// writes the user's own assistant settings.
final class Script: CommandRunner {
    private let state = Mutex<(commands: [ShellCommand], rules: [(match: String, code: Int32, lines: [String])])>(([], []))

    /// The first rule whose `match` is in the command's display line answers it; no rule exits 1.
    func on(_ match: String, code: Int32 = 0, lines: [String] = []) {
        state.withLock { $0.rules.append((match, code, lines)) }
    }

    var commands: [ShellCommand] { state.withLock { $0.commands } }
    /// The arguments of each command run at the CLI (not the `command -v` lookups).
    var calls: [[String]] { commands.filter { $0.executable != "/bin/zsh" }.map(\.arguments) }

    func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        let rule = state.withLock { s in
            s.commands.append(command)
            return s.rules.first { command.display.contains($0.match) }
        }
        for line in rule?.lines ?? [] { onLine(line) }
        return rule?.code ?? 1
    }
}

struct Home {
    let root: URL
    let script = Script()
    var apps: URL { root.appending(path: "Applications") }
    var desktopConfig: URL { root.appending(path: "Library/Application Support/Claude/claude_desktop_config.json") }
    var backup: URL { root.appending(path: "Library/Application Support/Claude/claude_desktop_config.json.lift-backup") }

    static let skillV1 = "---\nname: lift\ndescription: test v1\n---\nUse Lift.\n"
    static let skillV2 = "---\nname: lift\ndescription: test v2\n---\nUse Lift better.\n"

    init() throws { root = try UIFixtures.tempDir() }

    /// An executable named `tool` in `~/.local/bin`, where the connector looks after the login shell's PATH.
    @discardableResult
    func install(_ tool: String) throws -> String {
        let bin = root.appending(path: ".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let path = bin.appending(path: tool).path
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        return path
    }

    func installDesktopApp() throws {
        try FileManager.default.createDirectory(at: apps.appending(path: "Claude.app"), withIntermediateDirectories: true)
    }

    func writeDesktopConfig(_ text: String) throws {
        try FileManager.default.createDirectory(at: desktopConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: desktopConfig)
    }

    var desktopText: String { (try? String(contentsOf: desktopConfig, encoding: .utf8)) ?? "" }

    func skillFile(_ tool: String) -> URL { root.appending(path: ".\(tool)/skills/lift/SKILL.md") }
    func marker(_ tool: String) -> URL { root.appending(path: ".\(tool)/skills/lift/.installed-by-lift") }
    func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    func connector(port: Int = 7777, bridge: String? = "/Applications/Lift.app/Contents/MacOS/lift-mcp", skill: String? = Home.skillV1) -> AssistantConnector {
        AssistantConnector(mcpURL: "http://127.0.0.1:\(port)/mcp", bridge: bridge, skill: skill, runner: script, home: root,
                           searchDirs: [root.appending(path: ".local/bin").path], applications: [apps.appending(path: "Claude.app")])
    }
}

/// What `claude mcp get lift` prints for an HTTP entry.
func claudeGet(url: String, scope: String = "user") -> [String] {
    ["lift:", "  Scope: User config (available in all your projects)", "  Status: ✓ Connected", "  Type: http", "  URL: \(url)", "",
     "To remove this server, run: claude mcp remove \"lift\" -s \(scope)"]
}

/// What `codex mcp get lift --json` prints.
func codexGet(_ transport: String) -> [String] {
    ["{", "  \"name\": \"lift\",", "  \"enabled\": true,", "  \"transport\": \(transport)", "}"]
}

@Suite struct ClaudeCodeConnectorTests {
    @Test func notInstalledWhenTheCLIIsNowhere() async throws {
        let home = try Home()
        #expect(await home.connector().detect(.claudeCode) == .notInstalled)
    }

    @Test func findsTheCLIOnTheLoginShellsPath() async throws {
        let home = try Home()
        let elsewhere = try UIFixtures.tempDir().appending(path: "claude")
        FileManager.default.createFile(atPath: elsewhere.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        home.script.on("command -v claude", lines: [elsewhere.path])
        #expect(await home.connector().detect(.claudeCode) == .notConnected)
        #expect(home.script.commands.last?.executable == elsewhere.path)
        #expect(home.script.calls.last == ["mcp", "get", "lift"])
    }

    @Test func detectsConnectedOutdatedAndForeignEntries() async throws {
        let home = try Home()
        try home.install("claude")
        home.script.on("mcp get lift", lines: claudeGet(url: "http://127.0.0.1:7777/mcp"))
        #expect(await home.connector().detect(.claudeCode) == .connected)
        #expect(await home.connector(port: 7778).detect(.claudeCode) == .needsUpdate)

        let foreign = try Home()
        try foreign.install("claude")
        foreign.script.on("mcp get lift", lines: claudeGet(url: "https://lift.example.com/mcp"))
        #expect(await foreign.connector().detect(.claudeCode) == .taken)
    }

    @Test func connectAddsAUserScopedHTTPServer() async throws {
        let home = try Home()
        try home.install("claude")
        home.script.on("mcp add")
        try await home.connector().connect(.claudeCode)
        #expect(home.script.calls == [["mcp", "get", "lift"],
                                      ["mcp", "add", "--scope", "user", "--transport", "http", "lift", "http://127.0.0.1:7777/mcp"]])
    }

    @Test func connectReplacesLiftsOwnOldEntry() async throws {
        let home = try Home()
        try home.install("claude")
        home.script.on("mcp get lift", lines: claudeGet(url: "http://localhost:7777/mcp", scope: "local"))
        home.script.on("mcp remove")
        home.script.on("mcp add")
        try await home.connector(port: 7780).connect(.claudeCode)
        #expect(home.script.calls.dropFirst() == [["mcp", "remove", "--scope", "local", "lift"],
                                                  ["mcp", "add", "--scope", "user", "--transport", "http", "lift", "http://127.0.0.1:7780/mcp"]])
    }

    @Test func connectRefusesAForeignEntryUnlessAskedToReplaceIt() async throws {
        let home = try Home()
        try home.install("claude")
        home.script.on("mcp get lift", lines: claudeGet(url: "https://lift.example.com/mcp"))
        home.script.on("mcp remove")
        home.script.on("mcp add")
        await #expect(throws: AssistantError.taken(.claudeCode)) { try await home.connector().connect(.claudeCode) }
        #expect(home.script.calls == [["mcp", "get", "lift"]])

        try await home.connector().connect(.claudeCode, replacing: true)
        #expect(home.script.calls.suffix(2) == [["mcp", "remove", "--scope", "user", "lift"],
                                                ["mcp", "add", "--scope", "user", "--transport", "http", "lift", "http://127.0.0.1:7777/mcp"]])
    }

    @Test func disconnectRemovesTheEntry() async throws {
        let home = try Home()
        try home.install("claude")
        home.script.on("mcp get lift", lines: claudeGet(url: "http://127.0.0.1:7777/mcp"))
        home.script.on("mcp remove")
        try await home.connector().disconnect(.claudeCode)
        #expect(home.script.calls.last == ["mcp", "remove", "--scope", "user", "lift"])
    }

    @Test func aFailedCommandCarriesItsOutput() async throws {
        let home = try Home()
        try home.install("claude")
        home.script.on("mcp add", code: 1, lines: ["MCP server lift already exists"])
        do {
            try await home.connector().connect(.claudeCode)
            Issue.record("expected an error")
        } catch {
            #expect(Format.error(error).contains("MCP server lift already exists"))
        }
    }
}

@Suite struct CodexConnectorTests {
    static let addHelp = ["Usage: codex mcp add [OPTIONS] <NAME> (--url <URL> | -- <COMMAND>...)", "      --url <URL>"]
    static let oldAddHelp = ["Usage: codex mcp add [OPTIONS] <NAME> -- <COMMAND>..."]

    @Test func detectsFromTheJSONEntry() async throws {
        let home = try Home()
        #expect(await home.connector().detect(.codex) == .notInstalled)
        try home.install("codex")
        #expect(await home.connector().detect(.codex) == .notConnected)
        home.script.on("mcp get lift --json", lines: codexGet(#"{"type": "streamable_http", "url": "http://127.0.0.1:7777/mcp"}"#))
        #expect(await home.connector().detect(.codex) == .connected)
        #expect(await home.connector(port: 7001).detect(.codex) == .needsUpdate)
    }

    @Test func aBridgeEntryWithAnOldPortNeedsUpdating() async throws {
        let home = try Home()
        try home.install("codex")
        home.script.on("mcp get lift --json", lines: codexGet(
            #"{"type": "stdio", "command": "/Applications/Lift.app/Contents/MacOS/lift-mcp", "args": ["--url", "http://127.0.0.1:7777/mcp"]}"#))
        #expect(await home.connector().detect(.codex) == .connected)
        #expect(await home.connector(port: 7778).detect(.codex) == .needsUpdate)
    }

    @Test func connectUsesTheURLWhenCodexSupportsIt() async throws {
        let home = try Home()
        try home.install("codex")
        home.script.on("mcp add --help", lines: Self.addHelp)
        home.script.on("mcp add lift")
        try await home.connector().connect(.codex)
        #expect(home.script.calls.last == ["mcp", "add", "lift", "--url", "http://127.0.0.1:7777/mcp"])
    }

    @Test func connectFallsBackToTheBridgeWithoutURLSupport() async throws {
        let home = try Home()
        try home.install("codex")
        home.script.on("mcp add --help", lines: Self.oldAddHelp)
        home.script.on("mcp add lift")
        try await home.connector().connect(.codex)
        #expect(home.script.calls.last == ["mcp", "add", "lift", "--", "/Applications/Lift.app/Contents/MacOS/lift-mcp",
                                           "--url", "http://127.0.0.1:7777/mcp"])
    }

    @Test func connectReplacesAnOldEntryAndRefusesAForeignOne() async throws {
        let home = try Home()
        try home.install("codex")
        home.script.on("mcp get lift --json", lines: codexGet(#"{"type": "streamable_http", "url": "http://127.0.0.1:7000/mcp"}"#))
        home.script.on("mcp add --help", lines: Self.addHelp)
        home.script.on("mcp remove lift")
        home.script.on("mcp add lift")
        try await home.connector().connect(.codex)
        #expect(home.script.calls.suffix(2) == [["mcp", "remove", "lift"], ["mcp", "add", "lift", "--url", "http://127.0.0.1:7777/mcp"]])

        let foreign = try Home()
        try foreign.install("codex")
        foreign.script.on("mcp get lift --json", lines: codexGet(#"{"type": "stdio", "command": "npx", "args": ["lift-server"]}"#))
        await #expect(throws: AssistantError.taken(.codex)) { try await foreign.connector().connect(.codex) }
        #expect(!foreign.script.calls.contains { $0.contains("remove") || $0.contains("add") && !$0.contains("--help") })
    }

    @Test func disconnectRemovesTheEntry() async throws {
        let home = try Home()
        try home.install("codex")
        home.script.on("mcp remove lift")
        try await home.connector().disconnect(.codex)
        #expect(home.script.calls.last == ["mcp", "remove", "lift"])
    }
}

@Suite struct ClaudeDesktopConnectorTests {
    static let bridge = "/Applications/Lift.app/Contents/MacOS/lift-mcp"

    @Test func installedWhenTheAppOrItsSettingsExist() async throws {
        let home = try Home()
        #expect(await home.connector().detect(.claudeDesktop) == .notInstalled)
        try home.installDesktopApp()
        #expect(await home.connector().detect(.claudeDesktop) == .notConnected)

        let configOnly = try Home()
        try configOnly.writeDesktopConfig("{}")
        #expect(await configOnly.connector().detect(.claudeDesktop) == .notConnected)
    }

    @Test func connectWritesANewFileWhenThereIsNone() async throws {
        let home = try Home()
        try home.installDesktopApp()
        let note = try await home.connector().connect(.claudeDesktop)
        #expect(note == "Restart Claude to finish connecting.")
        let json = try JSONSerialization.jsonObject(with: Data(home.desktopText.utf8)) as? [String: Any]
        let lift = (json?["mcpServers"] as? [String: Any])?["lift"] as? [String: Any]
        #expect(lift?["command"] as? String == Self.bridge)
        #expect(lift?["args"] as? [String] == ["--url", "http://127.0.0.1:7777/mcp"])
        #expect(!FileManager.default.fileExists(atPath: home.backup.path))
        #expect(await home.connector().detect(.claudeDesktop) == .connected)
    }

    static let existing = """
    {
      "globalShortcut": "Alt+Space",
      "mcpServers": {
        "filesystem": {
          "command": "npx",
          "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Desktop"]
        }
      },
      "zeta": [1, 2.50, "x\\u00e9"]
    }

    """

    @Test func connectKeepsEveryOtherByteAndDisconnectPutsItBack() async throws {
        let home = try Home()
        try home.writeDesktopConfig(Self.existing)
        try await home.connector().connect(.claudeDesktop)
        #expect(home.desktopText == """
        {
          "globalShortcut": "Alt+Space",
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me/Desktop"]
            },
            "lift": {
              "command": "\(Self.bridge)",
              "args": [
                "--url",
                "http://127.0.0.1:7777/mcp"
              ]
            }
          },
          "zeta": [1, 2.50, "x\\u00e9"]
        }

        """)
        try await home.connector().disconnect(.claudeDesktop)
        #expect(home.desktopText == Self.existing)
    }

    @Test func connectAddsMCPServersWhenThereAreNone() async throws {
        let home = try Home()
        try home.writeDesktopConfig("{\n  \"theme\": \"dark\"\n}\n")
        try await home.connector().connect(.claudeDesktop)
        #expect(home.desktopText.hasPrefix("{\n  \"theme\": \"dark\",\n  \"mcpServers\": {\n    \"lift\": {\n      \"command\": "))
        #expect(home.desktopText.hasSuffix("\n    }\n  }\n}\n"))
    }

    @Test func theBackupIsWrittenOnceAndKept() async throws {
        let home = try Home()
        try home.writeDesktopConfig(Self.existing)
        try await home.connector().connect(.claudeDesktop)
        #expect(try String(contentsOf: home.backup, encoding: .utf8) == Self.existing)
        try await home.connector(port: 7790).connect(.claudeDesktop)
        try await home.connector().disconnect(.claudeDesktop)
        #expect(try String(contentsOf: home.backup, encoding: .utf8) == Self.existing)
    }

    @Test func malformedSettingsAreLeftAlone() async throws {
        let home = try Home()
        let broken = "{\n  \"mcpServers\": {\n    \"x\": { \"command\": \"y\", }\n"
        try home.writeDesktopConfig(broken)
        await #expect(throws: AssistantError.self) { try await home.connector().connect(.claudeDesktop) }
        await #expect(throws: AssistantError.self) { try await home.connector().disconnect(.claudeDesktop) }
        #expect(home.desktopText == broken)
        #expect(!FileManager.default.fileExists(atPath: home.backup.path))
    }

    @Test func disconnectRemovesOnlyLift() async throws {
        let home = try Home()
        let text = """
        {"mcpServers": {"lift": {"command": "\(Self.bridge)", "args": ["--url", "http://127.0.0.1:7777/mcp"]}, "other": {"command": "x"}}, "k": true}
        """
        try home.writeDesktopConfig(text)
        try await home.connector().disconnect(.claudeDesktop)
        #expect(home.desktopText == #"{"mcpServers": {"other": {"command": "x"}}, "k": true}"#)
    }

    @Test func anOldPortNeedsUpdatingAndUpdateReplacesOnlyTheValue() async throws {
        let home = try Home()
        try home.writeDesktopConfig(#"{"mcpServers": {"lift": {"command": "\#(Self.bridge)", "args": ["--url", "http://127.0.0.1:7777/mcp"]}}}"#)
        #expect(await home.connector(port: 7801).detect(.claudeDesktop) == .needsUpdate)
        try await home.connector(port: 7801).connect(.claudeDesktop)
        #expect(home.desktopText == #"{"mcpServers": {"lift": {"command": "\#(Self.bridge)", "args": ["--url", "http://127.0.0.1:7801/mcp"]}}}"#)
        #expect(await home.connector(port: 7801).detect(.claudeDesktop) == .connected)
    }

    @Test func aForeignLiftIsReplacedOnlyWhenAsked() async throws {
        let home = try Home()
        let text = #"{"mcpServers": {"lift": {"command": "uvx", "args": ["lift-tools"]}}}"#
        try home.writeDesktopConfig(text)
        #expect(await home.connector().detect(.claudeDesktop) == .taken)
        await #expect(throws: AssistantError.taken(.claudeDesktop)) { try await home.connector().connect(.claudeDesktop) }
        #expect(home.desktopText == text)
        try await home.connector().connect(.claudeDesktop, replacing: true)
        #expect(await home.connector().detect(.claudeDesktop) == .connected)
    }
}

@MainActor @Suite struct AssistantsModelTests {
    @Test func nothingRunsUntilTheAppSaysHow() async throws {
        let model = AssistantsModel()
        await model.check(mcpURL: "http://127.0.0.1:7777/mcp", bridge: nil)
        #expect(model.rows.isEmpty)
        #expect(model.connector == nil)
    }

    @Test func aPortChangeShowsUpdateConnection() async throws {
        let home = try Home()
        try home.install("claude")
        home.script.on("mcp get lift", lines: claudeGet(url: "http://127.0.0.1:7777/mcp"))
        let model = AssistantsModel()
        model.makeConnector = { url, bridge, _ in
            AssistantConnector(mcpURL: url, bridge: bridge, runner: home.script, home: home.root, searchDirs: [home.root.appending(path: ".local/bin").path],
                               applications: [])
        }
        await model.check(mcpURL: "http://127.0.0.1:7777/mcp", bridge: nil)
        #expect(model.rows[.claudeCode]?.state == .connected)
        #expect(model.rows[.codex]?.state == .notInstalled)
        #expect(model.needingUpdate.isEmpty)
        await model.check(mcpURL: "http://127.0.0.1:7778/mcp", bridge: nil)
        #expect(model.needingUpdate == [.claudeCode])
    }

    @Test func aFailureIsPlainWithTheOutputUnderDetails() async throws {
        let home = try Home()
        try home.install("codex")
        home.script.on("mcp add --help", lines: CodexConnectorTests.addHelp)
        home.script.on("mcp add lift", code: 2, lines: ["error: config.toml is read-only"])
        let model = AssistantsModel()
        model.makeConnector = { url, bridge, _ in
            AssistantConnector(mcpURL: url, bridge: bridge, runner: home.script, home: home.root, searchDirs: [home.root.appending(path: ".local/bin").path],
                               applications: [])
        }
        await model.check(mcpURL: "http://127.0.0.1:7777/mcp", bridge: nil)
        await model.connect(.codex)
        #expect(model.rows[.codex]?.failure == "Lift couldn't connect Codex.")
        #expect(model.rows[.codex]?.details?.contains("config.toml is read-only") == true)
        #expect(model.rows[.codex]?.busy == false)
    }

    @Test func connectingClaudeDesktopSaysToRestartIt() async throws {
        let home = try Home()
        try home.installDesktopApp()
        let model = AssistantsModel()
        model.makeConnector = { url, _, _ in home.connector(port: Int(URL(string: url)!.port!)) }
        await model.check(mcpURL: "http://127.0.0.1:7777/mcp", bridge: nil)
        await model.connect(.claudeDesktop)
        #expect(model.rows[.claudeDesktop]?.state == .connected)
        #expect(model.rows[.claudeDesktop]?.note == "Restart Claude to finish connecting.")
        await model.disconnect(.claudeDesktop)
        #expect(model.rows[.claudeDesktop]?.state == .notConnected)
        #expect(model.rows[.claudeDesktop]?.note == nil)
    }

    @Test func theServerStartingChecksTheAssistants() async throws {
        let home = try Home()
        try home.installDesktopApp()
        let skill = try UIFixtures.tempDir().appending(path: "SKILL.md")
        try Data("shipped skill".utf8).write(to: skill)
        let app = AppModel(defaults: MemoryPrefs(), paths: AppPaths(bundledRecipes: try UIFixtures.cubeBundle(), workerSource: UIFixtures.workerSource,
                                                                    bridge: nil, skill: skill),
                           secrets: MemorySecretStore(), serverPort: 0, checkPrereqs: { _ in readyTools }, hf: FakeHF(), weightsMetadata: OfflineHub())
        let seen = SeenMCP()
        app.assistants.makeConnector = { url, _, skill in
            seen.url = url
            seen.skill = skill
            return home.connector(port: Int(URL(string: url)!.port!))
        }
        #expect(await app.open(try UIFixtures.tempDir().appending(path: "workdir")))
        #expect(try await eventually { app.assistants.rows[.claudeDesktop]?.state == .notConnected })
        #expect(seen.url == app.serverStatus?.urls.mcp)
        #expect(seen.skill == "shipped skill")
        await app.close()
    }
}

@MainActor final class SeenMCP { var url: String?; var skill: String? }

/// The Lift skill: installed with the MCP connection for Claude Code and Codex, removed with it, and never
/// a file Lift didn't write (`.installed-by-lift` holds the SHA-256 of what it wrote).
@Suite struct SkillTests {
    static func ready(_ tool: String) throws -> Home {
        let home = try Home()
        try home.install(tool)
        home.script.on("mcp add")
        home.script.on("mcp remove")
        home.script.on("mcp get lift", lines: tool == "claude" ? claudeGet(url: "http://127.0.0.1:7777/mcp")
                       : codexGet(#"{"type": "streamable_http", "url": "http://127.0.0.1:7777/mcp"}"#))
        return home
    }

    static func sha(_ text: String) -> String { AssistantConnector.sha256(Data(text.utf8)) }

    @Test(arguments: [("claude", Assistant.claudeCode), ("codex", Assistant.codex)])
    func connectInstallsTheSkillWithItsMarker(_ tool: String, _ a: Assistant) async throws {
        let home = try Home()
        try home.install(tool)
        home.script.on("mcp add")
        #expect(home.connector().skillState(a) == .missing)
        try await home.connector().connect(a)
        #expect(home.text(home.skillFile(tool)) == Home.skillV1)
        #expect(home.text(home.marker(tool)) == Self.sha(Home.skillV1))
        #expect(home.connector().skillState(a) == .installed)
    }

    @Test func aNewerLiftUpdatesAnUneditedSkill() async throws {
        let home = try Self.ready("claude")
        try await home.connector().connect(.claudeCode)
        #expect(home.connector(skill: Home.skillV2).skillState(.claudeCode) == .outdated)
        try await home.connector(skill: Home.skillV2).connect(.claudeCode)
        #expect(home.text(home.skillFile("claude")) == Home.skillV2)
        #expect(home.text(home.marker("claude")) == Self.sha(Home.skillV2))
    }

    @Test func anEditedSkillIsKept() async throws {
        let home = try Self.ready("codex")
        try await home.connector().connect(.codex)
        try Data("my own notes\n".utf8).write(to: home.skillFile("codex"))
        #expect(home.connector(skill: Home.skillV2).skillState(.codex) == .edited)
        let note = try await home.connector(skill: Home.skillV2).connect(.codex)
        #expect(home.text(home.skillFile("codex")) == "my own notes\n")
        #expect(note == "You changed Lift's skill, so Lift kept your version.")
        try await home.connector().disconnect(.codex)
        #expect(home.text(home.skillFile("codex")) == "my own notes\n")
    }

    @Test func aForeignSkillIsNeverTouched() async throws {
        let home = try Self.ready("claude")
        let dir = home.skillFile("claude").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("someone else's".utf8).write(to: home.skillFile("claude"))
        #expect(home.connector().skillState(.claudeCode) == .foreign)
        let note = try await home.connector().connect(.claudeCode)
        #expect(note == "A different “lift” skill is already installed, so Lift left it alone.")
        #expect(home.text(home.skillFile("claude")) == "someone else's")
        #expect(!FileManager.default.fileExists(atPath: home.marker("claude").path))
        try await home.connector().disconnect(.claudeCode)
        #expect(home.text(home.skillFile("claude")) == "someone else's")
    }

    @Test func disconnectRemovesOnlyWhatLiftWrote() async throws {
        let home = try Self.ready("claude")
        try await home.connector().connect(.claudeCode)
        let dir = home.skillFile("claude").deletingLastPathComponent()
        try await home.connector().disconnect(.claudeCode)
        #expect(!FileManager.default.fileExists(atPath: dir.path))

        try await home.connector().connect(.claudeCode)
        try Data("mine".utf8).write(to: dir.appending(path: "notes.md"))
        try await home.connector().disconnect(.claudeCode)
        #expect(home.text(dir.appending(path: "notes.md")) == "mine")
        #expect(!FileManager.default.fileExists(atPath: home.skillFile("claude").path))
        #expect(!FileManager.default.fileExists(atPath: home.marker("claude").path))
    }

    @Test func claudeDesktopHasNoSkill() async throws {
        let home = try Home()
        try home.installDesktopApp()
        #expect(home.connector().skillState(.claudeDesktop) == nil)
        try await home.connector().connect(.claudeDesktop)
        #expect(!FileManager.default.fileExists(atPath: home.root.appending(path: ".claude").path))
    }

    @Test func noShippedSkillMeansMCPOnly() async throws {
        let home = try Self.ready("claude")
        try await home.connector(skill: nil).connect(.claudeCode)
        #expect(!FileManager.default.fileExists(atPath: home.skillFile("claude").path))
    }

    @MainActor @Test func launchingANewerLiftUpdatesAnUneditedSkill() async throws {
        let home = try Self.ready("claude")
        try await home.connector().connect(.claudeCode)
        let model = AssistantsModel()
        model.makeConnector = { _, _, skill in home.connector(skill: skill) }
        await model.check(mcpURL: "http://127.0.0.1:7777/mcp", bridge: nil, skill: Home.skillV2)
        #expect(home.text(home.skillFile("claude")) == Home.skillV2)
        #expect(model.rows[.claudeCode]?.skill == .installed)
        #expect(model.rows[.claudeDesktop]?.skill == nil)
    }

    /// The SKILL.md Lift.app ships: the right frontmatter, short, and only tools that exist.
    @Test func theShippedSkillNamesRealTools() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../skills/lift/SKILL.md").standardizedFileURL
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("---\nname: lift\ndescription: "))
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).count <= 120)
        let yaml = try String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../Sources/LiftServer/openapi.yaml").standardizedFileURL, encoding: .utf8)
        let tools = Set(yaml.matches(of: /operationId: (\w+)/).map { String($0.1) })
        let named = Set(text.matches(of: /`((?:jobs|models|queue|recipes|workers|resources|settings|server|secrets|system)_\w+)`/).map { String($0.1) })
        #expect(!named.isEmpty)
        #expect(named.subtracting(tools).isEmpty, "not Lift tools: \(named.subtracting(tools))")
        for tool in ["models_list", "models_get", "models_install", "models_download_weights", "jobs_submit", "jobs_wait", "jobs_export"] {
            #expect(named.contains(tool))
        }
    }
}
