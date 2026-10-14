import Foundation
import Hummingbird
import LiftCore
import NIOCore

/// Hummingbird's request context plus the peer address, which decides auth.
struct LiftContext: RequestContext, RemoteAddressRequestContext {
    var coreContext: CoreRequestContextStorage
    let remoteAddress: SocketAddress?

    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        remoteAddress = source.channel.remoteAddress
    }
}

/// Spec §10 auth. Requests from this Mac need no token, but their Host and Origin must name this Mac
/// too (a web page using DNS rebinding reaches 127.0.0.1 with its own Host). Other machines get in only
/// in LAN mode, with `Authorization: Bearer <token>`.
enum Access {
    enum Decision: Equatable {
        case allow
        case unauthorized
        case forbidden(String)
    }

    static func check(loopback: Bool, lanMode: Bool, token: String?, authorization: String?, host: String?, origin: String?) -> Decision {
        if loopback {
            if let host, !isLocal(host: host) { return .forbidden("Host \(host) is not this Mac") }
            if let origin, !(origin.hasPrefix("http://") && isLocal(host: String(origin.dropFirst("http://".count)))) {
                return .forbidden("Origin \(origin) is not this Mac")
            }
            return .allow
        }
        guard lanMode else { return .forbidden("LAN mode is off") }
        guard let token, let authorization, equal(authorization, "Bearer \(token)") else { return .unauthorized }
        return .allow
    }

    static func isLocal(host: String) -> Bool {
        let name = host.hasPrefix("[") ? String(host.prefix { $0 != "]" }.dropFirst()) : String(host.split(separator: ":").first ?? "")
        return ["127.0.0.1", "localhost", "::1"].contains(name)
    }

    static func isLoopback(_ address: SocketAddress?) -> Bool {
        guard let ip = address?.ipAddress else { return false }
        return ip.hasPrefix("127.") || ip == "::1" || ip.hasPrefix("::ffff:127.")
    }

    /// Constant time, so the token can't be guessed byte by byte from response times.
    static func equal(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

struct AccessMiddleware: RouterMiddleware {
    typealias Context = LiftContext
    let lanMode: Bool
    let secrets: any SecretStore
    /// Tests stand in for another machine; nil means the socket's peer address decides.
    let isRemote: (@Sendable (HTTPFields) -> Bool)?

    func handle(_ request: Request, context: LiftContext, next: (Request, LiftContext) async throws -> Response) async throws -> Response {
        let loopback = isRemote.map { !$0(request.headers) } ?? Access.isLoopback(context.remoteAddress)
        switch Access.check(loopback: loopback, lanMode: lanMode, token: secrets.get(.lanToken),
                            authorization: request.headers[.authorization], host: request.head.authority,
                            origin: request.headers[.origin]) {
        case .allow:
            return try await next(request, context)
        case .unauthorized:
            return Self.problem(Problem(error: "unauthorized", message: "send Authorization: Bearer <token> (see server_status on this Mac)", status: 401),
                                extra: [.wwwAuthenticate: "Bearer"])
        case .forbidden(let why):
            return Self.problem(Problem(error: "forbidden", message: why, status: 403))
        }
    }

    static func problem(_ p: Problem, extra: HTTPFields = [:]) -> Response {
        var headers: HTTPFields = [.contentType: "application/json"]
        headers.append(contentsOf: extra)
        return Response(status: .init(code: p.status), headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: p.json)))
    }
}
