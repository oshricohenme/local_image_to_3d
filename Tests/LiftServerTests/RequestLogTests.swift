import Foundation
import LiftCore
import MCP
import Testing
@testable import LiftServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct RequestLogTests {
    func entry(_ server: LiftServer, _ match: @escaping (RequestLogEntry) -> Bool) async throws -> RequestLogEntry? {
        var found: RequestLogEntry?
        _ = try await eventually(10) {
            found = await server.requestLog.snapshot()?.entries.first(where: match)
            return found != nil
        }
        return found
    }

    @Test func recordsHTTPAndMCPRequestsWithSecretsRedacted() async throws {
        let lift = try await Fixtures.lift()
        let server = Fixtures.server(lift)
        let status = try await server.start()
        let http = HTTP(base: URL(string: "http://127.0.0.1:\(status.port)")!)

        _ = try await http.call("GET", "/v1/queue")
        let queue = try #require(try await entry(server) { $0.summary == "GET /v1/queue" })
        #expect(queue.kind == .http && queue.status == 200 && !queue.failed)
        #expect(queue.response?.contains("max_slots") == true)

        _ = try await http.call("PUT", "/v1/secrets/hf-token", json: ["token": "hf_supersecret"])
        let secret = try #require(try await entry(server) { $0.path == "/v1/secrets/hf-token" })
        #expect(secret.request?.contains("hf_supersecret") == false)
        #expect(secret.request?.contains("[redacted]") == true)

        _ = try await http.call("GET", "/v1/jobs/nope")
        #expect(try await entry(server) { $0.path == "/v1/jobs/nope" }?.failed == true)

        let client = Client(name: "log-test", version: "1.0.0")
        _ = try await client.connect(transport: HTTPClientTransport(endpoint: URL(string: "http://127.0.0.1:\(status.port)/mcp")!))
        _ = try await client.callTool(name: "queue_status", arguments: [:])
        let call = try #require(try await entry(server) { $0.summary == "tools/call queue_status" })
        #expect(call.kind == .mcp && call.client == "log-test 1.0.0" && call.session != nil)
        #expect(call.response?.contains("max_slots") == true)

        // The file holds the same entries, so they survive a restart.
        let reloaded = RequestLog(file: server.requestLog.file)
        #expect(await reloaded.snapshot()?.entries.map(\.id) == server.requestLog.snapshot()?.entries.map(\.id))
        await server.stop()
        await lift.close()
    }

    @Test func redactsTokensAlsoInsideEscapedJSON() {
        #expect(RequestLog.redact(#"{"token":"hf_abc"}"#) == #"{"token":"[redacted]"}"#)
        #expect(RequestLog.redact(#"{"text":"{\"server\":{},\"token\":\"lan123\"}"}"#) == #"{"text":"{\"server\":{},\"token\":\"[redacted]\"}"}"#)
        #expect(RequestLog.redact(#"{"progressToken":"abc","token":null}"#) == #"{"progressToken":"abc","token":null}"#)
    }

    @Test func dropsTheOldestHalfPastItsSize() async throws {
        let file = try Fixtures.tempDir().appending(path: "logs/requests.jsonl")
        let log = RequestLog(file: file, maxBytes: 4000)
        for i in 0..<40 {
            await log.append(RequestLogEntry(id: UUID(), time: Date(), kind: .http, method: "GET", path: "/v1/\(i)", summary: "GET /v1/\(i)",
                                             client: nil, session: nil, from: nil, status: 200, failed: false, milliseconds: 1, request: nil, response: nil))
        }
        let entries = try #require(await log.snapshot()?.entries)
        #expect(entries.first?.path == "/v1/39" && entries.count < 40)
        #expect(try Data(contentsOf: file).count <= 4000)
        #expect(await RequestLog(file: file).snapshot()?.entries.map(\.id) == entries.map(\.id))
    }
}
