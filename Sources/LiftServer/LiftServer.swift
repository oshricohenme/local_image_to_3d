import Foundation
import HTTPTypes
import Hummingbird
import LiftCore
import Logging
import OpenAPIHummingbird
import ServiceLifecycle

public struct ServerStatus: Codable, Sendable, Equatable {
    public struct URLs: Codable, Sendable, Equatable {
        public var api: String
        public var openapi: String
        public var docs: String
        public var mcp: String
    }

    public struct MCPEntry: Codable, Sendable, Equatable {
        public var type: String
        public var url: String
    }

    /// The port the server listens on: the configured one, or the next free one when that was taken.
    public var port: Int
    public var configuredPort: Int
    /// 127.0.0.1, or 0.0.0.0 in LAN mode.
    public var bind: String
    public var lanMode: Bool
    public var tokenSet: Bool
    public var urls: URLs
    /// `{"mcpServers": {"lift": {"type": "http", "url": …}}}` for MCP clients. MCP is HTTP only, never stdio.
    public var mcpConfig: [String: [String: MCPEntry]]
}

public struct ServerChange: Codable, Sendable, Equatable {
    public var server: ServerStatus
    /// The bearer token other machines send (only in answers to server_set_lan and server_rotate_token).
    public var token: String?
}

/// Lift's HTTP server (spec §10): `/v1` generated from openapi.yaml, `/openapi.json`, `/docs` (Redoc) and
/// MCP at `/mcp`, all on one port. Owns the server_* commands, which both adapters call.
public actor LiftServer {
    public struct Configuration: Sendable {
        /// The LAN token and the Hugging Face token. The app passes `CachedSecretStore(KeychainSecretStore())` (and gives the same
        /// store's `hfTokenReader` to `LiftConfig`); the default keeps tests off the Keychain.
        public var secrets: any SecretStore
        /// nil: the `port` setting (7777 by default), else the next free port after it. 0: any free port (tests).
        public var port: Int?
        /// Tests only: treat a request as coming from another machine. nil: the socket's peer address decides.
        public var isRemote: (@Sendable (HTTPFields) -> Bool)?
        /// Wait this long before rebinding after server_set_lan, so the answer reaches the caller first.
        public var rebindDelay: Duration
        /// Where LAN mode listens. Tests keep it on 127.0.0.1 so they never open the Mac to the network.
        public var lanHost: String

        public init(secrets: any SecretStore = MemorySecretStore(), port: Int? = nil,
                    isRemote: (@Sendable (HTTPFields) -> Bool)? = nil, rebindDelay: Duration = .milliseconds(300), lanHost: String = "0.0.0.0") {
            self.secrets = secrets
            self.port = port
            self.isRemote = isRemote
            self.rebindDelay = rebindDelay
            self.lanHost = lanHost
        }
    }

    public nonisolated let lift: Lift
    /// Every MCP and HTTP API request (Settings → Show Log).
    public nonisolated let requestLog: RequestLog
    let configuration: Configuration
    var secrets: any SecretStore { configuration.secrets }
    var running: (group: ServiceGroup, task: Task<Void, any Error>, sessions: MCPSessions)?
    var restarting: Task<Void, Never>?
    public private(set) var port = 0
    var host = "127.0.0.1"
    var lan = false
    var configuredPort = 7777
    let logger: Logger = {
        var l = Logger(label: "lift.server")
        l.logLevel = .warning
        return l
    }()

    public init(lift: Lift, configuration: Configuration = .init()) {
        self.lift = lift
        self.configuration = configuration
        requestLog = RequestLog(file: lift.config.workdir.appending(path: "logs/requests.jsonl"))
    }

    /// Binds and serves. The configured port is tried first, then up to 19 after it (spec §13 "port taken").
    @discardableResult
    public func start() async throws -> ServerStatus {
        let settings = ServerSettings.load(lift.config.workdir)
        configuredPort = configuration.port ?? settings.port
        // A restart (server_set_lan) tries the port it had first, so clients keep their URL.
        let preferred = port != 0 ? [port] : []
        let candidates = preferred + (configuredPort == 0 ? [0] : Array(configuredPort..<min(configuredPort + 20, 65536)))
        var lastError: (any Error)?
        for candidate in candidates {
            do {
                try await bind(candidate, lan: settings.lanMode)
                return status()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? LiftError.invalidState("no port to bind")
    }

    func bind(_ candidate: Int, lan: Bool) async throws {
        let host = lan ? configuration.lanHost : "127.0.0.1"
        let sessions = MCPSessions(lift: lift, control: self)
        let router = Router(context: LiftContext.self)
        router.middlewares.add(RequestLogMiddleware(log: requestLog))
        router.middlewares.add(AccessMiddleware(lanMode: lan, secrets: secrets,
                                                isRemote: configuration.isRemote))
        try API(lift: lift, server: self).registerHandlers(on: router, middlewares: [ProblemMiddleware(), LocationMiddleware()])
        router.addDocs()
        router.addMCP(sessions)
        let (started, signal) = AsyncStream<Int>.makeStream()
        let app = Application(router: router, configuration: .init(address: .hostname(host, port: candidate), serverName: "Lift"),
                              onServerRunning: { signal.yield($0.localAddress?.port ?? candidate) }, logger: logger)
        let group = ServiceGroup(services: [app], gracefulShutdownSignals: [], logger: logger)
        // Detached: a rebind runs inside a request of the old server, and ServiceLifecycle keeps its
        // graceful-shutdown state in task-locals, which a plain Task would inherit (and stop at once).
        let task = Task.detached {
            defer { signal.finish() }
            try await group.run()
        }
        for await actual in started {
            (port, self.host, self.lan) = (actual, host, lan)
            running = (group, task, sessions)
            return
        }
        try await task.value  // it stopped before listening: rethrow the bind error
        throw LiftError.invalidState("the server stopped before it started")
    }

    /// Closes MCP sessions (their streams would hold a graceful shutdown open) and stops listening.
    /// A rebind in progress finishes first, so it can't bind again after this returns.
    public func stop() async {
        await restarting?.value
        await shutDown()
    }

    func shutDown() async {
        guard let running else { return }
        self.running = nil
        await running.sessions.closeAll()
        await running.group.triggerGracefulShutdown()
        // A graceful shutdown waits for requests in flight, and a jobs_wait may last an hour: give them
        // a moment, then cut them off (callers treat a dropped wait as "call again").
        let task = running.task
        let deadline = Task { try await Task.sleep(for: .seconds(2)); task.cancel() }
        _ = try? await task.value
        deadline.cancel()
    }

    // MARK: server_status / server_set_lan / server_rotate_token

    public func status() -> ServerStatus {
        let base = "http://127.0.0.1:\(port)"
        return ServerStatus(port: port, configuredPort: configuredPort, bind: host, lanMode: lan,
                            tokenSet: secrets.get(.lanToken) != nil,
                            urls: .init(api: "\(base)/v1", openapi: "\(base)/openapi.json", docs: "\(base)/docs", mcp: "\(base)/mcp"),
                            mcpConfig: ["mcpServers": ["lift": .init(type: "http", url: "\(base)/mcp")]])
    }

    /// Saves LAN mode, makes a token if there is none, and rebinds on the same port shortly after answering.
    public func setLAN(_ enabled: Bool, confirm: Bool = false) async throws -> Gated<ServerChange> {
        guard confirm else {
            return .confirmationRequired(enabled
                ? "Listens on all network interfaces (\(configuration.lanHost):\(port)). Other machines can use Lift with the bearer token; open MCP sessions reconnect."
                : "Listens on this Mac only (127.0.0.1:\(port)); other machines lose access and open MCP sessions reconnect.")
        }
        var settings = ServerSettings.load(lift.config.workdir)
        settings.lanMode = enabled
        do { try settings.save(lift.config.workdir) } catch { throw LiftError.invalidState("could not save server.json: \(error)") }
        if enabled && secrets.get(.lanToken) == nil { try storeToken(Self.newToken()) }
        let delay = configuration.rebindDelay
        Task {
            try? await Task.sleep(for: delay)
            await self.restart()
        }
        var next = status()
        next.bind = enabled ? configuration.lanHost : "127.0.0.1"
        next.lanMode = enabled
        return .done(ServerChange(server: next, token: enabled ? secrets.get(.lanToken) : nil))
    }

    public func rotateToken(confirm: Bool = false) throws -> Gated<ServerChange> {
        guard confirm else { return .confirmationRequired("Replaces the LAN bearer token; clients using the current one get 401 until they use the new one.") }
        let token = Self.newToken()
        try storeToken(token)
        return .done(ServerChange(server: status(), token: token))
    }

    /// The bearer token other machines use in LAN mode (for the UI to show and copy).
    public func lanToken() -> String? { secrets.get(.lanToken) }

    /// Saves the first-choice port; it applies the next time the server starts.
    public func setPort(_ port: Int) throws -> ServerStatus {
        guard (1...65535).contains(port) else { throw LiftError.invalidInput([FieldError("port", "must be 1–65535")]) }
        var settings = ServerSettings.load(lift.config.workdir)
        settings.port = port
        do { try settings.save(lift.config.workdir) } catch { throw LiftError.invalidState("could not save server.json: \(error)") }
        if configuration.port == nil { configuredPort = port }
        return status()
    }

    /// `secrets_set_hf_token`: stores the Hugging Face token (the Keychain in the app); `nil` or "" removes it.
    public func secretsSetHFToken(_ token: String?) throws -> SecretsStatus {
        do { try secrets.set(.hfToken, token.flatMap { $0.isEmpty ? nil : $0 }) } catch { throw LiftError.invalidState("could not store the token: \(error)") }
        return SecretsStatus(hfTokenSet: secrets.get(.hfToken) != nil)
    }

    /// `settings_get`: LiftCore's settings plus the server's `port` and `lan_mode`.
    func settings() async -> SettingsOut {
        SettingsOut(core: await lift.settingsGet(), server: ServerSettings.load(lift.config.workdir))
    }

    /// `settings_set`: `port` is the server's; every other key is LiftCore's (`lan_mode` has server_set_lan).
    func setSetting(_ key: String, _ value: SettingValue) async throws -> SettingsOut {
        if key == "port" {
            guard case .int(let port) = value else { throw LiftError.invalidInput([FieldError("port", "must be int")]) }
            _ = try setPort(port)
        } else {
            _ = try await lift.settingsSet(key, value)
        }
        return await settings()
    }

    /// One rebind at a time: a second server_set_lan waits for the first, so two never race for the port.
    func restart() async {
        let previous = restarting
        let next = Task {
            await previous?.value
            await shutDown()
            _ = try? await start()
        }
        restarting = next
        await next.value
    }

    func storeToken(_ token: String) throws {
        do { try secrets.set(.lanToken, token) } catch { throw LiftError.invalidState("could not store the token: \(error)") }
    }

    /// 32 random bytes, base64url.
    static func newToken() -> String {
        var g = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255, using: &g) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

