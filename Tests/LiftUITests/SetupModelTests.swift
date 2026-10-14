import Foundation
import LiftCore
import LiftServer
import Testing
@testable import LiftUI

/// What launch decides (spec §11, the user's rule): setup appears only when something it sets up is missing,
/// with only those steps. Nothing missing goes straight to the main window, whatever `setupDone` says.
@MainActor @Suite struct LaunchTests {
    static let noUV: AppModel.PrereqsCheck = { _ in Prereqs(tools: ToolPaths(brew: "/opt/homebrew/bin/brew", git: "/usr/bin/git", gitLfs: "/opt/homebrew/bin/git-lfs"), metalToolchain: nil) }

    func existingWorkdir(_ prefs: MemoryPrefs) throws -> URL {
        let dir = try UIFixtures.tempDir().appending(path: "lift")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        prefs.set(dir.path, forKey: "workdir")
        return dir
    }

    @Test func nothingMissingGoesStraightToTheMainWindow() async throws {
        let prefs = MemoryPrefs()
        let dir = try existingWorkdir(prefs)  // and no setupDone flag at all
        let app = try UIFixtures.newApp(prefs)
        await app.start()
        defer { Task { await app.close() } }
        #expect(app.phase == .ready && !app.needs.any && app.workdir == dir && app.lift != nil)
    }

    @Test func onlyAMissingToolShowsJustYourMacThenTheMainWindow() async throws {
        let prefs = MemoryPrefs()
        _ = try existingWorkdir(prefs)
        let app = try UIFixtures.newApp(prefs, check: Self.noUV)
        await app.start()
        defer { Task { await app.close() } }
        #expect(app.phase == .setup && app.lift != nil)
        let setup = SetupModel(app: app)
        #expect(setup.steps == [.mac] && setup.step == .mac)
        #expect(setup.railTitle == "Lift needs to fix one thing" && setup.heading == "A helper tool is missing")
        #expect(setup.toolRows.map(\.state) == [.ready, .ready, .ready, .needed])
        await setup.next(app)
        #expect(app.phase == .setup)  // Continue waits until the tool is there
        setup.prereqs = readyTools  // what Set Up My Mac returns once it's installed
        await setup.next(app)
        #expect(app.phase == .ready)  // a repair run has no "all set" screen
    }

    @Test func aWorkdirGoneOnALaterLaunchShowsJustYourFiles() async throws {
        let prefs = MemoryPrefs()
        prefs.set(try UIFixtures.tempDir().appending(path: "deleted").path, forKey: "workdir")
        prefs.set(true, forKey: "setupDone")
        let app = try UIFixtures.newApp(prefs)
        await app.start()
        defer { Task { await app.close() } }
        #expect(app.phase == .setup && app.lift == nil && app.alert == nil)
        let setup = SetupModel(app: app)
        #expect(setup.steps == [.files] && setup.heading == "Lift can't find its folder")
        setup.workdir = try UIFixtures.tempDir().appending(path: "lift")
        await setup.next(app)
        #expect(app.phase == .ready && app.workdir == setup.workdir && app.lift != nil)
    }

    @Test func aFirstRunWithEverythingElsePresentIsWelcomeFilesDone() async throws {
        let prefs = MemoryPrefs()
        let app = try UIFixtures.newApp(prefs)
        await app.start()
        defer { Task { await app.close() } }
        #expect(app.phase == .setup && app.needs.firstRun)
        let setup = SetupModel(app: app)
        #expect(setup.steps == [.welcome, .files, .done] && setup.step == .welcome && setup.railTitle == "Set up Lift")
        await setup.next(app)
        #expect(setup.step == .files && setup.heading == "Where should Lift keep its files?")
        setup.workdir = try UIFixtures.tempDir().appending(path: "lift")
        setup.exportDir = try UIFixtures.tempDir().appending(path: "exports")
        setup.cleanupAfterExport = true
        await setup.next(app)  // opens the folder: bundled recipes copied, server up
        #expect(setup.step == .done && app.phase == .setup)
        #expect(app.settings.exportDir == setup.exportDir.path && app.settings.cleanupAfterExport)
        #expect(app.generate.exportDir == setup.exportDir.path)  // Generate starts from it
        #expect(FileManager.default.fileExists(atPath: setup.workdir.appending(path: "recipes/bundled/shared").path))
        await setup.back(app)
        #expect(setup.step == .files)
        await setup.next(app)
        await setup.next(app)
        #expect(app.phase == .ready && app.section == .generate && prefs.string(forKey: "workdir") == setup.workdir.path)
        await app.close()

        let again = try UIFixtures.newApp(prefs)
        await again.start()  // the next launch goes straight to the main window
        #expect(again.phase == .ready && again.workdir == setup.workdir)
        await again.close()
    }

    @Test func aFirstRunMissingAToolAddsYourMac() async throws {
        let app = try UIFixtures.newApp(check: Self.noUV)
        await app.start()
        #expect(SetupModel(app: app).steps == [.welcome, .files, .mac, .done])
    }

    @Test func theMetalToolchainCountsOnlyWhenABundledRecipeNeedsIt() async throws {
        let noMetal: AppModel.PrereqsCheck = { metal in Prereqs(tools: readyTools.tools, metalToolchain: metal ? false : nil) }
        let cube = try UIFixtures.newApp(check: noMetal)  // the Test Cube needs no Metal
        await cube.start()
        #expect(SetupModel(app: cube).steps == [.welcome, .files, .done])
        let dev = try UIFixtures.newApp(bundle: UIFixtures.devRecipes, check: noMetal)  // Pixal3D and TRELLIS.2 do
        await dev.start()
        #expect(SetupModel(app: dev).steps == [.welcome, .files, .mac, .done])
    }

    @Test func withoutAToolsCheckLaunchTrustsTheTools() async throws {
        // The launch smoke test passes no check (AppDelegate under -LiftSmokeTest): the sidebar must come up.
        let prefs = MemoryPrefs()
        _ = try existingWorkdir(prefs)
        let app = try UIFixtures.newApp(prefs, check: nil)
        await app.start()
        defer { Task { await app.close() } }
        #expect(app.phase == .ready && app.prereqs == nil)
    }

    @Test func aSetupQuitAfterYourFilesResumesWithOnlyWhatsLeft() async throws {
        let prefs = MemoryPrefs()
        let app = try UIFixtures.newApp(prefs, check: Self.noUV)
        await app.start()
        let setup = SetupModel(app: app)
        await setup.next(app)
        setup.workdir = try UIFixtures.tempDir().appending(path: "lift")
        await setup.next(app)
        #expect(setup.step == .mac)
        await app.close()  // quit

        let again = try UIFixtures.newApp(prefs, check: Self.noUV)
        await again.start()
        defer { Task { await again.close() } }
        let resumed = SetupModel(app: again)
        #expect(again.phase == .setup && resumed.steps == [.mac] && again.workdir == setup.workdir)
    }
}

@MainActor @Suite struct SetupModelTests {
    @Test func aChosenFolderGetsALiftFolderInside() async throws {
        let setup = SetupModel(app: try UIFixtures.newApp())
        let documents = try UIFixtures.tempDir()
        setup.choose(documents)  // e.g. ~/Documents: Lift's files go in their own folder, never loose among the user's
        #expect(setup.workdir == documents.appending(path: "Lift"))
    }

    @Test func foldersAreShownAsFriendlyNamesAndBreadcrumbs() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let lift = home.appending(path: "Library/Application Support/Lift")
        #expect(SetupModel.breadcrumb(lift) == "Library › Application Support › Lift")
        #expect(SetupModel.friendlyName(lift) == "A “Lift” folder in your Library")
        #expect(SetupModel.breadcrumb(home.appending(path: "Documents/Lift Exports")) == "Documents › Lift Exports")
        #expect(SetupModel.friendlyName(home.appending(path: "Documents/Lift")) == "A “Lift” folder in Documents")
        #expect(SetupModel.breadcrumb(URL(filePath: "/Volumes/Big Disk/Stuff/Lift")) == "Big Disk › Stuff › Lift")
    }

    @Test func freeSpaceUsesPerModelEstimatesAndWarnsUnder25GB() async throws {
        var free: Int64 = 130_000_000_000
        let setup = SetupModel(app: try UIFixtures.newApp(), freeSpace: { _ in free })
        #expect(setup.space?.text == "Model sizes vary. Check each model's storage estimate before installing. This Mac has 130 GB free.")
        #expect(setup.space?.warning == false)
        free = 24_000_000_000
        #expect(setup.space?.warning == true)
        #expect(setup.space?.text.contains("only 24 GB free") == true)
        free = 25_000_000_000
        #expect(setup.space?.warning == false && setup.space?.text.hasSuffix("25 GB free.") == true)
    }

    @Test func theMacStepGoesFromMissingToInstallingToReady() async throws {
        let setup = SetupModel(app: try UIFixtures.newApp())
        setup.prereqs = Prereqs(tools: ToolPaths(git: "/usr/bin/git"), metalToolchain: false)
        #expect(setup.toolRows.map(\.state) == [.needed, .ready, .needed, .needed, .needed])
        #expect(setup.toolRows.map(\.name) == ["Homebrew", "git", "git-lfs", "uv", "Apple's graphics compiler"])
        #expect(setup.offerSetUp && setup.askPasswordNote && !setup.macReady)
        setup.installingTools = true
        #expect(setup.toolRows.map(\.state) == [.installing, .ready, .installing, .installing, .installing] && !setup.offerSetUp)
        setup.installingTools = false
        setup.toolsFailure = "Homebrew's download stopped. Check your internet connection."
        #expect(setup.toolRows[0].state == .failed("Homebrew's download stopped. Check your internet connection."))
        #expect(setup.offerSetUp)  // Try Again
        setup.toolsFailure = nil
        setup.prereqs = Prereqs(tools: readyTools.tools, metalToolchain: true)
        setup.installedTools = true
        #expect(setup.macReady && !setup.offerSetUp && setup.macStatus == "Your Mac is ready ✓")
    }

    @Test func aMacThatHasEverythingShowsNoButtonAndNoMetalRowUnlessNeeded() async throws {
        let setup = SetupModel(app: try UIFixtures.newApp())
        setup.prereqs = readyTools
        #expect(setup.toolRows.map(\.name) == ["Homebrew", "git", "git-lfs", "uv"])
        #expect(setup.macReady && !setup.offerSetUp && !setup.askPasswordNote)
        #expect(setup.macStatus == "Your Mac already has everything Lift needs ✓")
    }

    @Test func anIntelHomebrewIsExplainedAndTheNativeOneStillAdded() async throws {
        let setup = SetupModel(app: try UIFixtures.newApp())
        setup.prereqs = Prereqs(tools: ToolPaths(git: "/usr/bin/git", uv: "/x/uv", rosettaBrew: "/usr/local/bin/brew"), metalToolchain: nil)
        #expect(setup.rosettaNote == "We found an older copy of Homebrew made for Intel Macs. Lift leaves it alone and adds the Apple-silicon version.")
        #expect(setup.offerSetUp && setup.askPasswordNote)
        setup.prereqs = readyTools
        #expect(setup.rosettaNote == nil)
    }

    @Test func aFolderThatCantOpenKeepsTheWizard() async throws {
        let app = try UIFixtures.newApp()
        await app.start()
        let setup = SetupModel(app: app)
        await setup.next(app)
        setup.workdir = try UIFixtures.file("not-a-folder")
        await setup.next(app)
        #expect(setup.step == .files && app.phase == .setup && app.alert != nil)
    }
}
