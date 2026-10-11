import Foundation
import HTTPTypes
import Hummingbird
import LiftCore
import MCP

/// Streamable HTTP MCP at `/mcp`: one MCP `Server` and `StatefulHTTPServerTransport` per session, as the
/// SDK's own HTTP example does (Sources/MCPConformance/Server/HTTPApp.swift), adapted to Hummingbird.
actor MCPSessions {
    struct Session {
        let server: Server
        let transport: StatefulHTTPServerTransport
        let subscriptions: Subscriptions
        var lastSeen: Date
    }

    let lift: Lift
    let control: LiftServer
    var sessions: [String: Session] = [:]
    /// Sessions a client never closed are dropped after this long without a request.
    let idleTimeout: TimeInterval = 3600

    init(lift: Lift, control: LiftServer) {
        self.lift = lift
        self.control = control
    }

    func handle(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        if let id = request.header(HTTPHeaderName.sessionID), var session = sessions[id] {
            session.lastSeen = Date()
            sessions[id] = session
            let response = await session.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 { await close(id) }
            return response
        }
        if request.method.uppercased() == "POST", let body = request.body, let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           json["method"] as? String == "initialize" {
            return await open(request)
        }
        if request.header(HTTPHeaderName.sessionID) != nil { return .error(statusCode: 404, .invalidRequest("Not Found: Session not found or expired")) }
        return .error(statusCode: 400, .invalidRequest("Bad Request: Missing \(HTTPHeaderName.sessionID) header"))
    }

    struct FixedID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }

    func open(_ request: MCP.HTTPRequest) async -> MCP.HTTPResponse {
        for (id, s) in sessions where Date().timeIntervalSince(s.lastSeen) > idleTimeout { await close(id) }
        let id = UUID().uuidString
        // Host and Origin are checked by AccessMiddleware for every route, so the SDK's localhost-only
        // OriginValidator is left out; it would refuse LAN clients that passed the bearer check.
        let transport = StatefulHTTPServerTransport(
            sessionIDGenerator: FixedID(id: id),
            validationPipeline: StandardValidationPipeline(validators: [
                AcceptHeaderValidator(mode: .sseRequired), ContentTypeValidator(), ProtocolVersionValidator(), SessionValidator(),
            ]))
        let subscriptions = Subscriptions(lift: lift)
        let server = await Self.makeServer(lift: lift, control: control, subscriptions: subscriptions)
        do {
            try await server.start(transport: transport)
        } catch {
            return .error(statusCode: 500, .internalError("could not start the session: \(error)"))
        }
        sessions[id] = Session(server: server, transport: transport, subscriptions: subscriptions, lastSeen: Date())
        let response = await transport.handleRequest(request)
        if case .error = response { await close(id) }
        return response
    }

    func close(_ id: String) async {
        guard let s = sessions.removeValue(forKey: id) else { return }
        await s.subscriptions.cancelAll()
        await s.server.stop()
    }

    func closeAll() async {
        for id in sessions.keys { await close(id) }
    }

    static func makeServer(lift: Lift, control: LiftServer, subscriptions: Subscriptions) async -> Server {
        let server = Server(
            name: "Lift", version: "1.0.0",
            instructions: "Lift runs open-source generative models on this Mac. It executes exactly what you ask and never picks models or settings itself. Risky tools need confirm: true; without it they describe the impact and change nothing.",
            capabilities: .init(resources: .init(subscribe: true, listChanged: false), tools: .init(listChanged: false)))
        // Handlers reach their server weakly: the server keeps the handlers, so a strong capture would leak every session.
        let weak = WeakServer(server)
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: ToolCatalog.tools) }
        await server.withMethodHandler(CallTool.self) { params in
            var progress: Tools.Progress?
            if let token = params._meta?.progressToken {
                progress = { value, total, message in
                    try? await weak.server?.notify(ProgressNotification.message(.init(progressToken: token, progress: value, total: total, message: message)))
                }
            }
            return await Tools.call(params, Tools.Context(lift: lift, server: control, progress: progress))
        }
        await server.withMethodHandler(ListResources.self) { _ in .init(resources: Resources.fixed) }
        await server.withMethodHandler(ListResourceTemplates.self) { _ in .init(templates: Resources.templates) }
        await server.withMethodHandler(ReadResource.self) { params in .init(contents: try await Resources.read(params.uri, lift: lift)) }
        await server.withMethodHandler(ResourceSubscribe.self) { params in
            try await subscriptions.subscribe(params.uri) { uri in
                try? await weak.server?.notify(ResourceUpdatedNotification.message(.init(uri: uri)))
            }
            return Empty()
        }
        await server.withMethodHandler(ResourceUnsubscribe.self) { params in
            await subscriptions.unsubscribe(params.uri)
            return Empty()
        }
        return server
    }
}

final class WeakServer: Sendable {
    weak let server: Server?
    init(_ server: Server) { self.server = server }
}

extension Router where Context == LiftContext {
    /// POST, GET and DELETE `/mcp`, converted between Hummingbird and the SDK's framework-free HTTP types.
    func addMCP(_ sessions: MCPSessions) {
        for method in [HTTPTypes.HTTPRequest.Method.post, .get, .delete] {

            on("/mcp", method: method) { request, _ -> Response in
                let body = try await request.body.collect(upTo: 64 << 20)
                var headers: [String: String] = [:]
                for field in request.headers { headers[field.name.canonicalName] = headers[field.name.canonicalName].map { "\($0), \(field.value)" } ?? field.value }
                let response = await sessions.handle(MCP.HTTPRequest(method: request.method.rawValue, headers: headers,
                                                                     body: body.readableBytes > 0 ? Data(body.readableBytesView) : nil, path: "/mcp"))
                var fields = HTTPFields()
                for (name, value) in response.headers { if let name = HTTPField.Name(name) { fields[name] = value } }
                if case .stream(let stream, _) = response {
                    return Response(status: .init(code: response.statusCode), headers: fields,
                                    body: ResponseBody(asyncSequence: stream.map { ByteBuffer(bytes: $0) }))
                }
                return Response(status: .init(code: response.statusCode), headers: fields,
                                body: ResponseBody(byteBuffer: ByteBuffer(bytes: response.bodyData ?? Data())))
            }
        }
    }
}
