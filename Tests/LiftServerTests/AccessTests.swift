import Foundation
import Testing
@testable import LiftServer

@Suite struct AccessTests {
    func check(loopback: Bool = true, lan: Bool = false, auth: String? = nil, host: String? = "127.0.0.1:7777", origin: String? = nil) -> Access.Decision {
        Access.check(loopback: loopback, lanMode: lan, token: "secret", authorization: auth, host: host, origin: origin)
    }

    @Test func thisMacNeedsNoToken() {
        #expect(check() == .allow)
        #expect(check(host: "localhost:7777", origin: "http://localhost:7777") == .allow)
        #expect(check(host: "[::1]:7777") == .allow)
        #expect(check(host: nil) == .allow)
    }

    @Test func rebindingHostsAndOriginsAreRefused() {
        #expect(check(host: "evil.example:7777") == .forbidden("Host evil.example:7777 is not this Mac"))
        #expect(check(origin: "https://evil.example") == .forbidden("Origin https://evil.example is not this Mac"))
    }

    @Test func otherMachinesNeedLANModeAndTheToken() {
        #expect(check(loopback: false) == .forbidden("LAN mode is off"))
        #expect(check(loopback: false, lan: true) == .unauthorized)
        #expect(check(loopback: false, lan: true, auth: "Bearer wrong") == .unauthorized)
        #expect(check(loopback: false, lan: true, auth: "Bearer secret", host: "192.168.1.5:7777") == .allow)
    }
}
