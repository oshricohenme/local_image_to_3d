import Foundation
import MCP

/// `lift-mcp`: an MCP client's stdio ↔ the running Lift's Streamable HTTP endpoint (spec §10). Each line from
/// the client is POSTed to `/mcp`; every message from Lift (responses, progress and resource notifications)
/// goes back as a line. Lift itself is never started here.
public enum Bridge {
    public static func run(url: URL, token: String? = nil, stdio: StdioTransport = StdioTransport()) async throws {
        try await stdio.connect()
        let link = Link(url: url, token: token, stdio: stdio)
        try await link.open()
        var inFlight: [Task<Void, Never>] = []
        // One task per message: a POST answers when its request is done, and jobs_wait may take minutes.
        for try await message in await stdio.receive() {
            inFlight.append(Task { await link.forward(message) })
        }
        for task in inFlight { await task.value }  // answer what was asked before stdin closed
        await link.close()
        await stdio.disconnect()
    }

    /// A JSON-RPC error for a request Lift couldn't take (not running, wrong port, bad token).
    static func errorReply(to message: Data, error: any Error, url: URL) -> Data? {
        guard let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any], let id = json["id"], json["method"] != nil else { return nil }
        let text = error is URLError
            ? "Lift is not reachable at \(url.absoluteString) (\(error.localizedDescription)). Is the Lift app running?"
            : "Lift at \(url.absoluteString) could not take this request (\(error.localizedDescription))."
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": ["code": -32000, "message": text]]
        return try? JSONSerialization.data(withJSONObject: reply)
    }

    /// The HTTP side. The stdio client initializes once, so when Lift forgets the session (Lift restarted,
    /// LAN mode toggled, an idle session dropped) the link opens a new one, replays the client's handshake
    /// and resends the message, instead of failing every call until the client is restarted.
    actor Link {
        let url: URL, token: String?, stdio: StdioTransport
        var http: HTTPClientTransport?
        var pump: Task<Void, Never>?
        var initialize: [String: Any]?, initialized: Data?
        var reconnecting: Task<Void, any Error>?
        /// The id the replayed initialize goes out with; its answer is the bridge's, not the client's.
        let replayID = "lift-mcp-reconnect"

        init(url: URL, token: String?, stdio: StdioTransport) { (self.url, self.token, self.stdio) = (url, token, stdio) }

        func open() async throws {
            let token = token
            let fresh = HTTPClientTransport(endpoint: url, streaming: true, requestModifier: { request in
                var request = request
                if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
                return request
            })
            try await fresh.connect()
            let (stdio, replayID) = (stdio, replayID)
            pump?.cancel()
            pump = Task {
                do {
                    for try await message in await fresh.receive() {
                        if (try? JSONSerialization.jsonObject(with: message) as? [String: Any])?["id"] as? String == replayID { continue }
                        try await stdio.send(message)
                    }
                } catch {}
            }
            let old = http
            http = fresh
            await old?.disconnect()
        }

        func close() async {
            pump?.cancel()
            await http?.disconnect()
        }

        func forward(_ message: Data) async {
            let json = try? JSONSerialization.jsonObject(with: message) as? [String: Any]
            switch json?["method"] as? String {
            case "initialize": initialize = json
            case "notifications/initialized": initialized = message
            default: break
            }
            guard let sent = http else { return }
            do {
                try await sent.send(message)
            } catch where Self.sessionLost(error) && initialize != nil && json?["method"] as? String != "initialize" {
                do {
                    try await reconnect(replacing: sent)
                    try await http?.send(message)
                } catch {
                    await reply(message, error)
                }
            } catch {
                await reply(message, error)
            }
        }

        func reply(_ message: Data, _ error: any Error) async {
            if let reply = errorReply(to: message, error: error, url: url) { try? await stdio.send(reply) }
        }

        /// Several calls can fail on the old session at once: one reconnect serves them all.
        func reconnect(replacing old: HTTPClientTransport) async throws {
            guard http === old else { return }
            if let reconnecting { return try await reconnecting.value }
            let task = Task {
                try await self.open()
                guard var hello = self.initialize, let fresh = self.http else { return }
                hello["id"] = self.replayID
                try await fresh.send(try JSONSerialization.data(withJSONObject: hello))
                if let initialized = self.initialized { try await fresh.send(initialized) }
            }
            reconnecting = task
            defer { reconnecting = nil }
            try await task.value
        }

        /// 404 "Session expired" when Lift no longer knows the session; 400 when a message went out without one.
        static func sessionLost(_ error: any Error) -> Bool {
            guard case MCPError.internalError(let detail) = error else { return false }
            return detail == "Session expired" || detail == "Bad request"
        }
    }
}
