import Foundation
import LiftCore
import MCP
import Synchronization
import Testing
@testable import LiftServer

/// A real MCP client (the SDK's HTTPClientTransport) against the real server with Test Cube installed.
@Suite(.serialized, .timeLimit(.minutes(10))) struct MCPTests {
    func connect(_ base: URL) async throws -> Client {
        let client = Client(name: "lift-tests", version: "1.0.0")
        _ = try await client.connect(transport: HTTPClientTransport(endpoint: base.appending(path: "mcp")))
        return client
    }

    /// The JSON text of a tool result.
    func json(_ content: [Tool.Content]) throws -> [String: Any] {
        guard case .text(let text, _, _) = try #require(content.first) else { Issue.record("not text"); return [:] }
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    func submit(_ client: Client, settings: [String: Value] = [:]) async throws -> String {
        let (content, isError) = try await client.callTool(name: "jobs_submit", arguments: [
            "steps": [["recipe": "test-cube", "task": "image_to_3d", "inputs": ["image_path": .string(try Fixtures.image())], "settings": .object(settings)]],
        ])
        #expect(isError != true)
        return try #require(try json(content)["id"] as? String)
    }

    @Test func jobsExportReExportsAFinishedJob() async throws {
        let client = try await connect(try await ServerFixture.shared.get().base)
        let id = try await submit(client)
        _ = try await client.callTool(name: "jobs_wait", arguments: ["id": .string(id), "timeout_seconds": 120])
        let dir = try Fixtures.tempDir()
        let (content, isError) = try await client.callTool(name: "jobs_export", arguments: ["id": .string(id), "formats": ["glb"], "dir": .string(dir.path)])
        #expect(isError != true)
        let exports = try #require(try json(content)["exports"] as? [[String: Any]])
        #expect((exports.first?["path"] as? String)?.hasPrefix(dir.path) == true)
    }

    @Test func toolsAreTheSpecTable() async throws {
        let client = try await connect(try await ServerFixture.shared.get().base)
        #expect(Set(try await client.listTools().tools.map(\.name)) == ToolCatalogTests.specTools)
    }

    @Test func submitAndWaitSendProgressAndReturnOutputsAsPathsAndURIs() async throws {
        let client = try await connect(try await ServerFixture.shared.get().base)
        let progress = Mutex<[ProgressNotification.Parameters]>([])
        await client.onNotification(ProgressNotification.self) { message in progress.withLock { $0.append(message.params) } }
        let id = try await submit(client, settings: ["delay": 3])  // several updates spread over seconds, after the GET stream is up
        let (content, isError) = try await client.callTool(name: "jobs_wait", arguments: ["id": .string(id), "timeout_seconds": 120],
                                                           meta: Metadata(progressToken: .unique()))
        #expect(isError != true)
        let view = try json(content)
        #expect(view["state"] as? String == "succeeded")
        let output = try #require((view["outputs"] as? [[String: Any]])?.first)
        let uri = try #require(output["uri"] as? String)
        #expect((output["path"] as? String)?.hasSuffix("cube.glb") == true)
        #expect(content.contains { if case .resourceLink(let u, _, _, _, _, _) = $0 { u == uri } else { false } })
        #expect(try await eventually(5) { progress.withLock { $0.contains { $0.message?.contains("Generating") == true } } })
        let values = progress.withLock { $0.map(\.progress) }
        #expect(values == values.sorted() && progress.withLock { $0.allSatisfy { $0.total == 1 } })

        let blob = try #require(try await client.readResource(uri: uri).first?.blob)
        #expect(Data(base64Encoded: blob)?.prefix(4) == Data("glTF".utf8))
        let job = try #require(try await client.readResource(uri: "lift://jobs/\(id)").first?.text)
        #expect(job.contains(#""state":"succeeded""#))
        #expect(try await client.readResource(uri: "lift://models/test-cube/install-log").first?.text?.contains("installed test-cube") == true)
        #expect(try await client.readResource(uri: "lift://resources").first?.text?.contains("budget_bytes") == true)
    }

    @Test func resultsArriveWithoutTheNotificationStream() async throws {
        // A client that never opens the GET stream misses progress (the SDK sends notifications there) but gets its answer.
        let client = Client(name: "no-sse", version: "1.0.0")
        _ = try await client.connect(transport: HTTPClientTransport(endpoint: try await ServerFixture.shared.get().base.appending(path: "mcp"), streaming: false))
        let id = try await submit(client)
        let (content, isError) = try await client.callTool(name: "jobs_wait", arguments: ["id": .string(id), "timeout_seconds": 120],
                                                           meta: Metadata(progressToken: .unique()))
        #expect(isError != true)
        #expect(try json(content)["state"] as? String == "succeeded")
    }

    @Test func subscribersHearAboutJobChanges() async throws {
        let client = try await connect(try await ServerFixture.shared.get().base)
        let updates = Mutex<[String]>([])
        await client.onNotification(ResourceUpdatedNotification.self) { message in updates.withLock { $0.append(message.params.uri) } }
        let id = try await submit(client, settings: ["delay": 3])  // several updates spread over seconds, after the GET stream is up
        try await client.subscribeToResource(uri: "lift://jobs/\(id)")
        #expect(try await eventually { updates.withLock { $0.contains("lift://jobs/\(id)") } })
        _ = try await client.callTool(name: "jobs_wait", arguments: ["id": .string(id), "timeout_seconds": 120])
    }

    @Test func gatesAndBadInputAreErrorResults() async throws {
        let client = try await connect(try await ServerFixture.shared.get().base)
        let id = try await submit(client)
        _ = try await client.callTool(name: "jobs_wait", arguments: ["id": .string(id), "timeout_seconds": 120])
        let (gate, gateError) = try await client.callTool(name: "jobs_delete", arguments: ["id": .string(id)])
        #expect(gateError == true)
        #expect(try json(gate)["error"] as? String == "confirmation_required")
        let (bad, badError) = try await client.callTool(name: "jobs_submit", arguments: [
            "steps": [["recipe": "test-cube", "task": "image_to_3d", "settings": ["size": 0]]],
        ])
        #expect(badError == true)
        #expect((try json(bad)["fields"] as? [[String: Any]])?.compactMap { $0["field"] as? String } == ["steps[0].settings.size", "steps[0].inputs.image"])
        let (_, deleted) = try await client.callTool(name: "jobs_delete", arguments: ["id": .string(id), "confirm": true])
        #expect(deleted != true)
    }

    @Test func aLANRebindEndsSessionsAndANewOneWorksOnTheSameURL() async throws {
        let lift = try await Fixtures.lift()
        let server = Fixtures.server(lift)
        let base = URL(string: "http://127.0.0.1:\(try await server.start().port)")!
        let before = try await connect(base)
        _ = try gated(await server.setLAN(true, confirm: true))
        #expect(try await eventually { await server.status().lanMode })
        await #expect(throws: (any Error).self) { _ = try await before.listTools() }
        let after = try await connect(base)
        #expect(try await after.listTools().tools.count == ToolCatalogTests.specTools.count)
        await server.stop()
    }
}

@Suite struct ToolCatalogTests {
    /// Spec §10's table, plus models_readme (spec §4a). Recipes come only with the app, so the only
    /// recipe command is recipes_list.
    static let specTools: Set<String> = [
        "jobs_submit", "jobs_list", "jobs_get", "jobs_wait", "jobs_cancel", "jobs_retry", "jobs_move", "jobs_set_priority",
        "jobs_force_start", "jobs_delete", "jobs_export", "jobs_list_interrupted", "jobs_resolve_interrupted",
        "queue_status", "queue_resume",  // pausing is the app's Pause button only
        "models_list", "models_get", "models_install", "models_reinstall", "models_set_pin", "models_check_upstream",
        "models_uninstall", "models_install_log", "models_readme", "models_download_weights", "models_verify_weights",
        "models_cancel_install", "recipes_list",
        "downloads_list", "downloads_pause", "downloads_resume", "downloads_cancel", "downloads_retry", "downloads_reorder",
        "workers_list", "workers_load", "workers_unload", "resources_get", "resources_set",
        "settings_get", "settings_set", "server_status", "server_set_lan", "server_rotate_token", "secrets_set_hf_token",
        "system_prereqs", "system_install_prereqs",
    ]

    @Test func everyOperationIsATool() {
        #expect(Set(ToolCatalog.tools.map(\.name)) == Self.specTools)
        #expect(Set(Tools.handlers.keys) == Self.specTools)
    }

    @Test func argumentsComeFromParametersAndBody() throws {
        let submit = try #require(ToolCatalog.tools.first { $0.name == "jobs_submit" })
        #expect(submit.inputSchema.objectValue?["required"] == ["steps"])
        let steps = submit.inputSchema.objectValue?["properties"]?.objectValue?["steps"]
        #expect(steps?.objectValue?["items"]?.objectValue?["properties"]?.objectValue?["recipe"] != nil)  // $ref inlined
        let delete = try #require(ToolCatalog.tools.first { $0.name == "jobs_delete" })
        #expect(delete.inputSchema.objectValue?["required"] == ["id"])
        #expect(delete.inputSchema.objectValue?["properties"]?.objectValue?["confirm"] != nil)
        #expect(delete.annotations.destructiveHint == true)
        #expect(ToolCatalog.tools.first { $0.name == "jobs_list" }?.annotations.readOnlyHint == true)
    }
}

@Suite struct ResourceURITests {
    @Test func urisParseBackToTheirTargets() {
        let out = OutputFile(job: "j1", path: "/w/jobs/j1/steps/0/my mesh é.glb")
        #expect(Resources.parse(out.uri) == .output(job: "j1", file: "my mesh é.glb"))
        #expect(Resources.parse("lift://jobs/j1") == .job("j1"))
        #expect(Resources.parse("lift://models/test-cube/install-log") == .installLog("test-cube"))
        #expect(Resources.parse("lift://resources") == .resources)
        #expect(Resources.parse("lift://jobs/j1/nope") == nil)
    }
}
