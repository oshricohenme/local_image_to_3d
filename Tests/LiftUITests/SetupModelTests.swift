import Foundation
import LiftCore
import LiftServer
import Testing
@testable import LiftUI

@MainActor @Suite struct SetupModelTests {
    @Test func firstLaunchRunsTheWizardUntilItsFinished() async throws {
        let prefs = MemoryPrefs()
        let app = try UIFixtures.newApp(prefs)
        await app.start()
        #expect(app.phase == .setup)
        let setup = SetupModel(app: app)
        #expect(setup.step == .folders)
        setup.workdir = try UIFixtures.tempDir().appending(path: "lift")
        #expect(setup.exportDir.lastPathComponent == "Lift Exports" && !setup.cleanupAfterExport)
        setup.exportDir = try UIFixtures.tempDir().appending(path: "exports")
        setup.cleanupAfterExport = true
        await setup.next(app)  // opens the folder: bundled recipes copied, tools checked, server up
        #expect(setup.step == .toolchain && app.phase == .setup && setup.prereqs != nil)
        #expect(app.settings.exportDir == setup.exportDir.path && app.settings.cleanupAfterExport)
        #expect(app.generate.exportDir == setup.exportDir.path)  // Generate starts from it
        #expect(FileManager.default.fileExists(atPath: setup.workdir.appending(path: "recipes/bundled/shared").path))
        await setup.next(app)
        #expect(setup.step == .recipes && setup.recipes.contains { $0.id == "test-cube" })
        await setup.next(app)
        setup.hfToken = "hf_test"
        await setup.next(app)
        #expect(setup.step == .mcp && app.secrets.get(.hfToken) == "hf_test" && setup.hfToken.isEmpty)
        await setup.next(app)
        #expect(app.phase == .ready && prefs.bool(forKey: "setupDone") && prefs.string(forKey: "workdir") == setup.workdir.path)
        await app.close()

        let again = try UIFixtures.newApp(prefs)
        await again.start()  // the next launch goes straight to the main window
        #expect(again.phase == .ready && again.workdir == setup.workdir)
        await again.close()
    }

    @Test func aSetupQuitHalfwayResumesWhereItStopped() async throws {
        let prefs = MemoryPrefs()
        let app = try UIFixtures.newApp(prefs)
        await app.start()
        let setup = SetupModel(app: app)
        setup.workdir = try UIFixtures.tempDir().appending(path: "lift")
        await setup.next(app)
        await setup.next(app)
        #expect(setup.step == .recipes)
        await app.close()  // quit

        let again = try UIFixtures.newApp(prefs)
        await again.start()
        defer { Task { await again.close() } }
        #expect(again.phase == .setup && again.lift != nil)
        let resumed = SetupModel(app: again)
        await resumed.load(again)
        #expect(resumed.step == .recipes && resumed.workdir == setup.workdir && resumed.recipes.contains { $0.id == "test-cube" })
    }

    @Test func aFolderThatCantOpenKeepsTheWizard() async throws {
        let app = try UIFixtures.newApp()
        await app.start()
        let setup = SetupModel(app: app)
        setup.workdir = try UIFixtures.file("not-a-folder")
        await setup.next(app)
        #expect(setup.step == .folders && app.phase == .setup && app.alert != nil)
    }
}
