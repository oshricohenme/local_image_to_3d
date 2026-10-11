import Foundation
import LiftCore
import Testing
@testable import LiftUI

/// First launch: no workdir yet, so the engine isn't open. Nothing the system or a stray click does
/// before setup may surface an internal "isn't open" error (seen on the first real run: macOS sets the
/// menu-bar extra's `isInserted` binding at launch, which wrote the `menu_bar` setting to a closed engine).
@MainActor @Suite struct BeforeSetupTests {
    @Test func settingTheMenuBarBeforeSetupIsQuiet() async throws {
        let app = try UIFixtures.newApp()
        app.setMenuBar(true)
        app.setMenuBar(false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(app.alert == nil)
        #expect(app.settings.menuBar == false)  // remembered locally, applied once Lift opens
    }

    /// Regression (froze the app on first launch): SwiftUI's menu-bar extra re-sets `isInserted` on every
    /// redraw; writing the same value again must not count as a change, or the redraw loops forever.
    @Test func setMenuBarToTheSameValueIsNotAChange() throws {
        let app = try UIFixtures.newApp()
        final class Flag: @unchecked Sendable { var changed = false }
        let flag = Flag()
        withObservationTracking { _ = app.settings.menuBar } onChange: { flag.changed = true }
        app.setMenuBar(app.settings.menuBar)
        #expect(!flag.changed)
    }

    @Test func anActionBeforeSetupGetsAPlainMessage() async throws {
        let app = try UIFixtures.newApp()
        app.run { _ = try await app.engine.queuePause() }
        #expect(try await eventually { app.alert != nil })
        #expect(app.alert?.contains("isn't open") == false)
        #expect(app.alert?.contains("setup") == true)
    }

    @Test func theMenuBarChoiceMadeBeforeSetupIsSavedOnOpen() async throws {
        let app = try UIFixtures.newApp()
        app.setMenuBar(false)
        #expect(await app.open(try UIFixtures.tempDir().appending(path: "workdir")))
        defer { Task { await app.close() } }
        #expect(try await app.engine.settingsGet().menuBar == false)
    }
}
