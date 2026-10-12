import Foundation
import HTTPTypes
import Hummingbird
import Synchronization

/// One MCP or HTTP API request and its answer, as Settings → Show Log lists it.
public struct RequestLogEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case mcp, http }

    public var id: UUID
    public var time: Date
    public var kind: Kind
    public var method: String
    /// With the query string.
    public var path: String
    /// "tools/call jobs_submit" for MCP, "GET /v1/queue" for the HTTP API.
    public var summary: String
    /// The MCP client's name from its `initialize` (e.g. "claude-code 2.1"), else the User-Agent.
    public var client: String?
    public var session: String?
    /// The caller's address (another machine in LAN mode).
    public var from: String?
    public var status: Int
    /// An HTTP error status, a JSON-RPC error or a tool result with `isError`.
    public var failed: Bool
    public var milliseconds: Int
    public var request: String?
    public var response: String?
}

/// Every MCP and HTTP API request, kept in `<workdir>/logs/requests.jsonl` (one JSON entry per line) for debugging.
/// Past `maxBytes` the oldest half is dropped. Secrets (`"token"` values) are redacted before anything is stored.
public actor RequestLog {
    public nonisolated let file: URL
    let maxBytes: Int
    /// Oldest first.
    var entries: [RequestLogEntry]
    var bytes: Int
    /// Bumped on every change, so a window showing the log reloads only when something happened.
    public private(set) var version = 0
    /// MCP session id → its client's name, learned from `initialize`.
    var clients: [String: String] = [:]

    public init(file: URL, maxBytes: Int = 20 << 20) {
        self.file = file
        self.maxBytes = maxBytes
        let data = (try? Data(contentsOf: file)) ?? Data()
        let decoder = Self.decoder
        entries = data.split(separator: UInt8(ascii: "\n")).compactMap { try? decoder.decode(RequestLogEntry.self, from: Data($0)) }
        bytes = data.count
    }

    /// Newest first, with the version they belong to; nil when nothing changed since `known`.
    public func snapshot(newerThan known: Int = -1) -> (version: Int, entries: [RequestLogEntry])? {
        version == known ? nil : (version, entries.reversed())
    }

    public func clear() {
        entries = []
        bytes = 0
        try? FileManager.default.removeItem(at: file)
        version += 1
    }

    func client(session: String) -> String? { clients[session] }
    func setClient(_ name: String, session: String) { clients[session] = name }

    func append(_ entry: RequestLogEntry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(UInt8(ascii: "\n"))
        entries.append(entry)
        bytes += line.count
        version += 1
        if bytes > maxBytes {
            entries.removeFirst(entries.count / 2)
            rewrite()
            return
        }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {}  // a log that can't be written must never fail the request
    }

    func rewrite() {
        var data = Data()
        for e in entries { if let line = try? Self.encoder.encode(e) { data.append(line); data.append(UInt8(ascii: "\n")) } }
        bytes = data.count
        try? data.write(to: file, options: .atomic)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Each body is kept up to this size; the rest is noted, not stored.
    static let bodyLimit = 64 << 10

    /// `"token":"…"` → `"token":"[redacted]"`, also inside JSON carried as a string (an MCP tool result's text),
    /// where the quotes are escaped. Covers the Hugging Face token and the LAN bearer token.
    static func redact(_ text: String) -> String {
        text.replacing(#/(\\*"token\\*"\s*:\s*\\*")[^"\\]+/#) { "\($0.1)[redacted]" }
    }

    /// A body as text: JSON and plain text as is (an event stream's `data:` payloads only), anything else as a size note.
    static func text(_ data: Data, total: Int, contentType: String?) -> String? {
        guard total > 0 else { return nil }
        let type = contentType?.lowercased() ?? ""
        guard type.isEmpty || type.contains("json") || type.hasPrefix("text/") else { return "(\(total) bytes of \(type))" }
        var text = String(decoding: data, as: UTF8.self)
        if type.hasPrefix("text/event-stream") {
            text = text.split(separator: "\n").filter { $0.hasPrefix("data:") }.map { $0.dropFirst(5).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        }
        if total > data.count { text += "\n… (\(total - data.count) more bytes not kept)" }
        return redact(text)
    }

    /// "tools/call jobs_submit", "resources/read lift://queue", "initialize": what an MCP request asked for.
    static func mcpSummary(_ body: Data) -> (summary: String, client: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return ("MCP", nil) }
        guard let method = json["method"] as? String else { return ("response to the server", nil) }
        let params = json["params"] as? [String: Any]
        switch method {
        case "tools/call": return ("tools/call \(params?["name"] as? String ?? "?")", nil)
        case "resources/read", "resources/subscribe", "resources/unsubscribe": return ("\(method) \(params?["uri"] as? String ?? "?")", nil)
        case "initialize":
            let info = params?["clientInfo"] as? [String: Any]
            let name = [info?["name"] as? String, info?["version"] as? String].compactMap { $0 }.joined(separator: " ")
            return (method, name.isEmpty ? nil : name)
        default: return (method, nil)
        }
    }

    /// A JSON-RPC error or a tool result marked `isError`, anywhere in an MCP answer.
    static func mcpFailed(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.contains(#""isError":true"#) || text.contains(#""error":{"#)
    }
}

/// Records every `/mcp` and `/v1` request in the `RequestLog`. Runs before access checks, so refused requests show too.
struct RequestLogMiddleware: RouterMiddleware {
    typealias Context = LiftContext
    let log: RequestLog

    /// The first `RequestLog.bodyLimit` bytes of a response as it streams out, and its full size.
    final class Capture: Sendable {
        let state = Mutex((data: Data(), total: 0))
        func add(_ buffer: ByteBuffer) {
            state.withLock { s in
                s.total += buffer.readableBytes
                let room = RequestLog.bodyLimit - s.data.count
                if room > 0 { s.data.append(contentsOf: buffer.readableBytesView.prefix(room)) }
            }
        }
    }

    func handle(_ request: Request, context: LiftContext, next: (Request, LiftContext) async throws -> Response) async throws -> Response {
        let path = request.uri.path
        let kind: RequestLogEntry.Kind
        if path == "/mcp" { kind = .mcp } else if path.hasPrefix("/v1/") || path == "/v1" { kind = .http } else { return try await next(request, context) }
        let start = ContinuousClock.now
        var request = request
        let contentType = request.headers[.contentType]
        let textual = contentType.map { $0.contains("json") || $0.hasPrefix("text/") } ?? true
        var requestText: String?
        var requestBody = Data()
        if textual {
            let buffer = try await request.collectBody(upTo: 64 << 20)
            requestBody = Data(buffer.readableBytesView)
            requestText = RequestLog.text(requestBody.prefix(RequestLog.bodyLimit), total: requestBody.count, contentType: contentType)
        } else {
            requestText = "(\(request.headers[.contentLength] ?? "?") bytes of \(contentType ?? "?"))"
        }

        var entry = RequestLogEntry(id: UUID(), time: Date(), kind: kind, method: request.method.rawValue, path: request.uri.description,
                                    summary: "\(request.method.rawValue) \(path)", client: request.headers[.userAgent],
                                    session: request.headers[HTTPField.Name("Mcp-Session-Id")!],
                                    from: context.remoteAddress?.ipAddress, status: 0, failed: false, milliseconds: 0, request: requestText, response: nil)
        if kind == .mcp {
            if request.method == .post {
                let (summary, client) = RequestLog.mcpSummary(requestBody)
                entry.summary = summary
                if let client { entry.client = client }
            } else {
                entry.summary = request.method == .get ? "open the server's message stream" : "close the session"
            }
            if let session = entry.session, let client = await log.client(session: session) { entry.client = client }
        }

        let log = self.log
        @Sendable func elapsed() -> Int { Int((ContinuousClock.now - start) / .milliseconds(1)) }
        var response: Response
        do {
            response = try await next(request, context)
        } catch {
            entry.status = Int((error as? any HTTPResponseError)?.status.code ?? 500)
            entry.failed = true
            entry.milliseconds = elapsed()
            entry.response = "\(error)"
            await log.append(entry)
            throw error
        }
        entry.status = response.status.code
        if kind == .mcp, entry.summary == "initialize", let session = response.headers[HTTPField.Name("Mcp-Session-Id")!] {
            entry.session = session
            if let client = entry.client { await log.setClient(client, session: session) }
        }
        let responseType = response.headers[.contentType]
        // The GET stream stays open for the whole session: recorded when it opens, its messages aren't kept.
        if kind == .mcp && request.method == .get && response.status.code < 300 {
            entry.milliseconds = elapsed()
            entry.response = "(the stream stays open; its messages aren't logged)"
            await log.append(entry)
            return response
        }
        let capture = Capture()
        let body = response.body
        let finished = entry
        response.body = ResponseBody(contentLength: body.contentLength) { writer in
            var entry = finished
            func record(_ error: (any Error)?) async {
                let (data, total) = capture.state.withLock { ($0.data, $0.total) }
                entry.milliseconds = elapsed()
                entry.response = RequestLog.text(data, total: total, contentType: responseType)
                if let error { entry.response = (entry.response.map { $0 + "\n" } ?? "") + "(the answer stopped: \(error))" }
                entry.failed = entry.status >= 400 || error != nil || (kind == .mcp && RequestLog.mcpFailed(entry.response))
                await log.append(entry)
            }
            do {
                try await body.map { capture.add($0); return $0 }.write(writer)
                await record(nil)
            } catch {
                await record(error)
                throw error
            }
        }
        return response
    }
}
