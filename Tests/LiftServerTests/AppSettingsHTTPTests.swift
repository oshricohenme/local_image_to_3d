import Foundation
import Testing
@testable import LiftCore
@testable import LiftServer

/// The app's settings change over HTTP like any other (spec §10 parity; Lift.app follows them).
@Suite struct AppSettingsHTTPTests {
    @Test func appAndExportSettingsAreSettable() async throws {
        let lift = try await Fixtures.lift()
        let server = Fixtures.server(lift)
        let status = try await server.start()
        defer { Task { await server.stop() } }
        let http = HTTP(base: URL(string: "http://127.0.0.1:\(status.port)")!)
        for (key, value) in [("menu_bar", false), ("launch_at_login", true), ("notifications", false), ("cleanup_after_export", true)] as [(String, Any)] {
            let set = try await http.call("POST", "/v1/settings", json: ["key": key, "value": value])
            #expect(set.status == 200 && set.json[key] as? Bool == value as? Bool, "\(key)")
        }
        let dir = try await http.call("POST", "/v1/settings", json: ["key": "export_dir", "value": "/tmp/lift-exports"])
        #expect(dir.status == 200 && dir.json["export_dir"] as? String == "/tmp/lift-exports")
        let s = await lift.settingsGet()
        #expect(!s.menuBar && s.launchAtLogin && !s.notifications && s.cleanupAfterExport && s.exportDir == "/tmp/lift-exports")
    }
}
