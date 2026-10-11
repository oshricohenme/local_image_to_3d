import Foundation
import KeychainAccess
import Synchronization

public enum SecretKey: String, Sendable, CaseIterable {
    case hfToken = "hf_token"
    case lanToken = "lan_token"
}

/// Where tokens live (spec §3: the Keychain). Injectable, so tests never touch the real Keychain.
public protocol SecretStore: Sendable {
    func get(_ key: SecretKey) -> String?
    func set(_ key: SecretKey, _ value: String?) throws
}

/// For tests, and for a server configured without a store. Nothing is persisted.
public final class MemorySecretStore: SecretStore {
    private let values: Mutex<[SecretKey: String]>

    public init(_ values: [SecretKey: String] = [:]) { self.values = Mutex(values) }

    public func get(_ key: SecretKey) -> String? { values.withLock { $0[key] } }
    public func set(_ key: SecretKey, _ value: String?) { values.withLock { $0[key] = value } }
}

/// The login Keychain through KeychainAccess. The app passes this; tests don't.
public struct KeychainSecretStore: SecretStore {
    public let service: String

    public init(service: String = "Lift") { self.service = service }

    public func get(_ key: SecretKey) -> String? { try? Keychain(service: service).get(key.rawValue) }

    public func set(_ key: SecretKey, _ value: String?) throws {
        let keychain = Keychain(service: service)
        if let value { try keychain.set(value, key: key.rawValue) } else { try keychain.remove(key.rawValue) }
    }
}

/// Reads each key from `base` once, then remembers it; writes go through and update what's remembered.
/// Each Keychain read can ask for the login password, and the Models screen asks for the token on every redraw.
public final class CachedSecretStore: SecretStore {
    let base: any SecretStore
    /// Held across the first read, so two callers at once still mean one read (one password prompt).
    private let cache = Mutex<[SecretKey: String?]>([:])

    public init(_ base: any SecretStore) { self.base = base }

    public func get(_ key: SecretKey) -> String? {
        cache.withLock { cache in
            if let known = cache[key] { return known }
            let value = base.get(key)
            cache[key] = .some(value)
            return value
        }
    }

    public func set(_ key: SecretKey, _ value: String?) throws {
        try cache.withLock { cache in
            try base.set(key, value)
            cache[key] = .some(value)
        }
    }
}

extension SecretStore {
    /// For `LiftConfig(hfToken:)`: the stored Hugging Face token, else `$HF_TOKEN`.
    public var hfTokenReader: @Sendable () -> String? {
        { [self] in get(.hfToken) ?? ProcessInfo.processInfo.environment["HF_TOKEN"] }
    }
}

public struct SecretsStatus: Codable, Sendable, Equatable {
    public var hfTokenSet: Bool
}
