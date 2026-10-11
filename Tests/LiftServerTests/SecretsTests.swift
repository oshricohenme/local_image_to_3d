import Synchronization
import Testing
@testable import LiftServer

/// A store that counts its reads, standing in for the Keychain (each read there can ask for the password).
final class CountingSecretStore: SecretStore {
    let reads = Mutex(0)
    let values = Mutex<[SecretKey: String]>([:])

    func get(_ key: SecretKey) -> String? {
        reads.withLock { $0 += 1 }
        return values.withLock { $0[key] }
    }

    func set(_ key: SecretKey, _ value: String?) { values.withLock { $0[key] = value } }
}

struct SecretsTests {
    /// The Models screen asks for the token on every redraw; the Keychain must be read once per key per launch.
    @Test func eachKeyIsReadOnceThenRemembered() throws {
        let base = CountingSecretStore()
        base.set(.hfToken, "hf_x")
        let store = CachedSecretStore(base)
        #expect(store.get(.hfToken) == "hf_x" && store.get(.hfToken) == "hf_x" && store.get(.lanToken) == nil && store.get(.lanToken) == nil)
        #expect(base.reads.withLock { $0 } == 2)
        try store.set(.hfToken, "hf_y")
        try store.set(.lanToken, nil)
        #expect(store.get(.hfToken) == "hf_y" && store.get(.lanToken) == nil && base.values.withLock { $0[.hfToken] } == "hf_y")
        #expect(base.reads.withLock { $0 } == 2)
    }
}
