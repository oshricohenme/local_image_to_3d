import Foundation

/// The server's own settings (spec §11: port and LAN mode), in `<workdir>/server.json`.
public struct ServerSettings: Codable, Sendable, Equatable {
    /// The first-choice port; a change applies the next time the server starts.
    public var port = 7777
    /// Bind 0.0.0.0 and accept bearer-token requests from other machines.
    public var lanMode = false

    enum CodingKeys: String, CodingKey { case port, lanMode = "lan_mode" }

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 7777
        lanMode = try c.decodeIfPresent(Bool.self, forKey: .lanMode) ?? false
    }

    static func url(_ workdir: URL) -> URL { workdir.appending(path: "server.json") }

    /// Defaults when the file is missing or unreadable.
    public static func load(_ workdir: URL) -> ServerSettings {
        (try? JSONDecoder().decode(ServerSettings.self, from: Data(contentsOf: url(workdir)))) ?? ServerSettings()
    }

    public func save(_ workdir: URL) throws {
        try JSONEncoder().encode(self).write(to: Self.url(workdir), options: .atomic)
    }
}
