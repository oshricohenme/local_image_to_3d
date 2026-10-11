import Foundation
import MCP

/// `lift-mcp`: an MCP client's stdio ↔ the running Lift's Streamable HTTP endpoint (spec §10). Each line from
/// the client is POSTed to `/mcp`; every message from Lift (responses, progress and resource notifications)
/// goes back as a line. Lift itself is never started here.
public enum Bridge {
    public static func run(url: URL, token: String? = nil, stdio: StdioTransport = StdioTransport()) async throws {
        let http = HTTPClientTransport(endpoint: url, streaming: true, requestModifier: { request in
            var request = request
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            return request
        })
        try await stdio.connect()
        try await http.connect()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var inFlight: [Task<Void, Never>] = []
                for try await message in await stdio.receive() {
                    // One task per message: a POST answers when its request is done, and jobs_wait may take minutes.
                    inFlight.append(Task {
                        do { try await http.send(message) } catch {
                            if let reply = errorReply(to: message, error: error, url: url) { try? await stdio.send(reply) }
                        }
                    })
                }
                for task in inFlight { await task.value }  // answer what was asked before stdin closed
            }
            group.addTask {
                for try await message in await http.receive() { try await stdio.send(message) }
            }
            // stdin closed (the client quit) or Lift went away: stop.
            try await group.next()
            group.cancelAll()
        }
        await http.disconnect()
        await stdio.disconnect()
    }

    /// A JSON-RPC error for a request Lift couldn't take (not running, wrong port, bad token).
    static func errorReply(to message: Data, error: any Error, url: URL) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any], let id = json["id"], json["method"] != nil else { return nil }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                    "error": ["code": -32000, "message": "Lift is not reachable at \(url.absoluteString) (\(error.localizedDescription)). Is the Lift app running?"]]
        return try? JSONSerialization.data(withJSONObject: reply)
    }
}
