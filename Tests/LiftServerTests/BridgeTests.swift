import Foundation
import MCP
import System
import Testing
@testable import LiftServer
@testable import lift_mcp

/// lift-mcp's bridge, in process: an MCP client on one pair of pipes, the bridge on the other, the real server behind it.
@Suite(.serialized, .timeLimit(.minutes(10))) struct BridgeTests {
    func json(_ content: [Tool.Content]) throws -> [String: Any] {
        guard case .text(let text, _, _) = try #require(content.first) else { Issue.record("not text"); return [:] }
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func theStdioBridgeForwardsToTheServer() async throws {
        let base = try await ServerFixture.shared.get().base
        let toBridge = Pipe(), toClient = Pipe()
        let bridge = Task {
            try await Bridge.run(url: base.appending(path: "mcp"), stdio: StdioTransport(
                input: FileDescriptor(rawValue: toBridge.fileHandleForReading.fileDescriptor),
                output: FileDescriptor(rawValue: toClient.fileHandleForWriting.fileDescriptor)))
        }
        let client = Client(name: "stdio-client", version: "1.0.0")
        _ = try await client.connect(transport: StdioTransport(
            input: FileDescriptor(rawValue: toClient.fileHandleForReading.fileDescriptor),
            output: FileDescriptor(rawValue: toBridge.fileHandleForWriting.fileDescriptor)))
        #expect(try await client.listTools().tools.count == ToolCatalogTests.specTools.count)
        let (content, isError) = try await client.callTool(name: "queue_status")
        #expect(isError != true)
        #expect(try json(content)["max_slots"] as? Int == 1)
        await client.disconnect()
        try toBridge.fileHandleForWriting.close()  // stdin EOF: the bridge exits
        _ = try await bridge.value
    }

    @Test func theBridgeAnswersRequestsWhenLiftIsDown() throws {
        let url = URL(string: "http://127.0.0.1:9/mcp")!
        let reply = try #require(Bridge.errorReply(to: Data(#"{"jsonrpc":"2.0","id":7,"method":"tools/list"}"#.utf8), error: URLError(.cannotConnectToHost), url: url))
        let json = try #require(try JSONSerialization.jsonObject(with: reply) as? [String: Any])
        #expect(json["id"] as? Int == 7 && (json["error"] as? [String: Any])?["code"] as? Int == -32000)
        #expect(Bridge.errorReply(to: Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), error: URLError(.cannotConnectToHost), url: url) == nil)
    }
}
