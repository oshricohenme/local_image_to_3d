import Foundation
@testable import LiftCore
import LiftServer
import Testing
@testable import LiftUI

/// Hugging Face without the network: `users` maps keys to account names, `access` gated repos to whether they're open.
struct FakeHF: HFAccount {
    var users: [String: String] = [:]
    var access: [String: Bool] = [:]
    var bytes: Int? = nil

    func whoami(token: String) async throws -> String? { users[token] }
    func canAccess(repo: String, token: String) async throws -> Bool { users[token] != nil && access[repo] == true }
    func size(of weights: [Recipe.Weight]) async -> Int? { bytes }
}

/// Every tool present: what a Mac that's ready looks like.
let readyTools = Prereqs(tools: ToolPaths(brew: "/opt/homebrew/bin/brew", git: "/usr/bin/git", uv: "/opt/homebrew/bin/uv"), metalToolchain: nil)

extension UIFixtures {
    /// An app whose bundle is all of `dev-recipes/` (Pixal3D, TRELLIS.2, UniRig, Test Cube), opened on a temp workdir.
    @MainActor static func devApp(developer: Bool = false) async throws -> AppModel {
        let app = AppModel(defaults: MemoryPrefs(), paths: AppPaths(bundledRecipes: devRecipes, workerSource: workerSource, bridge: nil),
                           secrets: MemorySecretStore(), serverPort: 0)
        #expect(await app.open(try tempDir().appending(path: "workdir"), ready: false))
        if developer { _ = try await app.engine.settingsSet("dev_recipes", .bool(true)) }
        await app.refresh()
        return app
    }
}

@MainActor @Suite struct SetupModelTests {
    @Test func firstLaunchRunsTheWizardUntilItsFinished() async throws {
        let prefs = MemoryPrefs()
        let app = try UIFixtures.newApp(prefs)
        await app.start()
        #expect(app.phase == .setup)
        let setup = SetupModel(app: app, hf: FakeHF())
        #expect(setup.step == .welcome)
        await setup.next(app)
        #expect(setup.step == .files)
        setup.workdir = try UIFixtures.tempDir().appending(path: "lift")
        #expect(setup.exportDir.lastPathComponent == "Lift Exports" && !setup.cleanupAfterExport)
        setup.exportDir = try UIFixtures.tempDir().appending(path: "exports")
        setup.cleanupAfterExport = true
        await setup.next(app)  // opens the folder: bundled recipes copied, tools checked, server up
        #expect(setup.step == .mac && app.phase == .setup && setup.prereqs != nil)
        #expect(app.settings.exportDir == setup.exportDir.path && app.settings.cleanupAfterExport)
        #expect(app.generate.exportDir == setup.exportDir.path)  // Generate starts from it
        #expect(FileManager.default.fileExists(atPath: setup.workdir.appending(path: "recipes/bundled/shared").path))
        setup.prereqs = readyTools
        await setup.next(app)
        #expect(setup.step == .model)
        await setup.skipModel(app)
        #expect(setup.step == .done && setup.chosen == nil)
        await setup.next(app)
        #expect(app.phase == .ready && prefs.bool(forKey: "setupDone") && prefs.string(forKey: "workdir") == setup.workdir.path)
        await app.close()

        let again = try UIFixtures.newApp(prefs)
        await again.start()  // the next launch goes straight to the main window
        #expect(again.phase == .ready && again.workdir == setup.workdir)
        await again.close()
    }

    @Test func aChosenFolderGetsALiftFolderInside() async throws {
        let setup = SetupModel(app: try UIFixtures.newApp(), hf: FakeHF())
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

    @Test func freeSpaceSaysHowManyModelsFitAndWarnsUnder25GB() async throws {
        var free: Int64 = 130_000_000_000
        let setup = SetupModel(app: try UIFixtures.newApp(), hf: FakeHF(), freeSpace: { _ in free })
        #expect(setup.space?.text == "Models are large — each one needs about 6 to 20 GB. This Mac has 130 GB free, enough for about 6 models.")
        #expect(setup.space?.warning == false)
        free = 24_000_000_000
        #expect(setup.space?.warning == true)
        #expect(setup.space?.text.contains("only 24 GB free") == true)
        free = 25_000_000_000
        #expect(setup.space?.warning == false && setup.space?.text.hasSuffix("enough for about 1 model.") == true)
    }

    @Test func theMacStepGoesFromMissingToInstallingToReady() async throws {
        let setup = SetupModel(app: try UIFixtures.newApp(), hf: FakeHF())
        setup.prereqs = Prereqs(tools: ToolPaths(git: "/usr/bin/git"), metalToolchain: false)
        #expect(setup.toolRows.map(\.state) == [.needed, .ready, .needed, .needed])
        #expect(setup.toolRows.map(\.name) == ["Homebrew", "git", "uv", "Apple's graphics compiler"])
        #expect(setup.offerSetUp && setup.askPasswordNote && !setup.macReady)
        setup.installingTools = true
        #expect(setup.toolRows.map(\.state) == [.installing, .ready, .installing, .installing] && !setup.offerSetUp)
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
        let setup = SetupModel(app: try UIFixtures.newApp(), hf: FakeHF())
        setup.prereqs = readyTools
        #expect(setup.toolRows.map(\.name) == ["Homebrew", "git", "uv"])
        #expect(setup.macReady && !setup.offerSetUp && !setup.askPasswordNote)
        #expect(setup.macStatus == "Your Mac already has everything Lift needs ✓")
    }

    @Test func anIntelHomebrewIsExplainedAndTheNativeOneStillAdded() async throws {
        let setup = SetupModel(app: try UIFixtures.newApp(), hf: FakeHF())
        setup.prereqs = Prereqs(tools: ToolPaths(git: "/usr/bin/git", uv: "/x/uv", rosettaBrew: "/usr/local/bin/brew"), metalToolchain: nil)
        #expect(setup.rosettaNote == "We found an older copy of Homebrew made for Intel Macs. Lift leaves it alone and adds the Apple-silicon version.")
        #expect(setup.offerSetUp && setup.askPasswordNote)
        setup.prereqs = readyTools
        #expect(setup.rosettaNote == nil)
    }

    @Test func modelCardsAreImageTo3DRecipesWithAddOnsApart() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        let setup = SetupModel(app: app, hf: FakeHF())
        #expect(setup.cards(app).map(\.id) == ["pixal3d", "trellis2-mac"])  // no Test Cube (developer only), no UniRig
        #expect(setup.addOns(app).map(\.id) == ["unirig"])
        let pixal = try #require(setup.cards(app).first)
        #expect(pixal.task == "Photo → 3D model" && pixal.credit.hasPrefix("by Dong-Yang Li") && pixal.credit.hasSuffix("· MIT"))
        #expect(pixal.gated == ["briaai/RMBG-2.0"] && pixal.description?.contains("one photo") == true)
        #expect(pixal.restrictions.contains("Not for commercial use: RMBG-2.0 by BRIA AI (CC-BY-NC-4.0)"))
        #expect(pixal.size == "About 3 GB")  // the recipe's estimate while the weights' size is unknown
        #expect(setup.addOns(app).first?.gated == [])

        let dev = try await UIFixtures.devApp(developer: true)
        defer { Task { await dev.close() } }
        #expect(SetupModel(app: dev, hf: FakeHF()).cards(dev).map(\.id).contains("test-cube"))
    }

    @Test func aModelsSizeIsItsWeightsOnceHuggingFaceSaysSo() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        let setup = SetupModel(app: app, hf: FakeHF(bytes: 14_200_000_000))
        setup.step = .model
        await setup.load(app)
        #expect(setup.cards(app).first?.size == "About 14.2 GB")
    }

    @Test func aModelWithoutGatedWeightsSkipsTheAccessStep() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        let setup = SetupModel(app: app, hf: FakeHF())
        setup.step = .model
        setup.selected = "test-cube"
        await setup.installChosen(app)
        #expect(setup.step == .done && setup.chosen?.id == "test-cube")
        #expect(app.aboutBeforeInstall?.id == "test-cube")  // the one-time About sheet, then the install's own confirmation
        await setup.back(app)
        #expect(setup.step == .model)
    }

    @Test func aGatedModelGoesThroughAccessAndInstallsOnlyOnceItsGranted() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        let setup = SetupModel(app: app, hf: FakeHF(users: ["hf_good": "ada"], access: ["briaai/RMBG-2.0": true]))
        setup.step = .model
        setup.selected = "pixal3d"
        await setup.installChosen(app)
        #expect(setup.step == .access && app.aboutBeforeInstall == nil)  // the install needs the key first
        #expect(setup.accessComponents == "RMBG-2.0 by BRIA AI")
        #expect(!setup.accessGranted)
        setup.hfToken = "hf_good"
        await setup.checkToken(app)
        #expect(setup.hfUser == "ada" && setup.repoAccess == ["briaai/RMBG-2.0": true] && setup.accessGranted)
        await setup.next(app)
        #expect(setup.step == .done && app.aboutBeforeInstall?.id == "pixal3d")
        await setup.back(app)
        #expect(setup.step == .access)
    }

    @Test func aBadKeyIsRefusedAndNotKept() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        let setup = SetupModel(app: app, hf: FakeHF(users: ["hf_good": "ada"]))
        setup.chosen = setup.cards(app).first { $0.id == "trellis2-mac" }
        setup.step = .access
        setup.hfToken = "hf_typo"
        await setup.checkToken(app)
        #expect(setup.hfUser == nil && setup.tokenProblem != nil && !setup.accessGranted)
        #expect(app.secrets.get(.hfToken) == nil)
    }

    @Test func aGoodKeyWithOneRepoStillWaitingKeepsContinueOff() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        let hf = FakeHF(users: ["hf_good": "ada"], access: ["facebook/dinov3-vitl16-pretrain-lvd1689m": true, "briaai/RMBG-2.0": false])
        let setup = SetupModel(app: app, hf: hf)
        setup.chosen = setup.cards(app).first { $0.id == "trellis2-mac" }
        setup.step = .access
        setup.hfToken = "hf_good"
        await setup.checkToken(app)
        #expect(setup.hfUser == "ada" && setup.tokenProblem == nil && app.secrets.get(.hfToken) == "hf_good" && setup.hfToken.isEmpty)
        #expect(setup.repoAccess == ["facebook/dinov3-vitl16-pretrain-lvd1689m": true, "briaai/RMBG-2.0": false] && !setup.accessGranted)
        await setup.next(app)
        #expect(setup.step == .access)  // Continue waits for every repo
        await setup.skipAccess(app)
        #expect(setup.step == .done && app.aboutBeforeInstall == nil)  // nothing installs without access
    }

    @Test func aSetupQuitHalfwayResumesWhereItStopped() async throws {
        let prefs = MemoryPrefs()
        let app = try UIFixtures.newApp(prefs)
        await app.start()
        let setup = SetupModel(app: app, hf: FakeHF())
        setup.step = .files
        setup.workdir = try UIFixtures.tempDir().appending(path: "lift")
        await setup.next(app)
        setup.prereqs = readyTools
        await setup.next(app)
        #expect(setup.step == .model)
        await app.close()  // quit

        let again = try UIFixtures.newApp(prefs)
        await again.start()
        defer { Task { await again.close() } }
        #expect(again.phase == .setup && again.lift != nil)
        let resumed = SetupModel(app: again, hf: FakeHF())
        #expect(resumed.step == .model && resumed.workdir == setup.workdir)
    }

    @Test func aStepSavedByTheOlderWizardResumesAtItsNewPlace() async throws {
        for (old, new) in [("0", SetupModel.Step.files), ("1", .mac), ("2", .model), ("3", .model), ("4", .done), ("access", .model)] {
            let prefs = MemoryPrefs()
            prefs.set(try UIFixtures.tempDir().appending(path: "lift").path, forKey: "workdir")
            prefs.set(old, forKey: "setupStep")
            let app = try UIFixtures.newApp(prefs)
            await app.start()
            #expect(SetupModel(app: app, hf: FakeHF()).step == new, "saved \(old)")  // Access without a chosen model goes back to Model
            await app.close()
        }
    }

    @Test func aFolderThatCantOpenKeepsTheWizard() async throws {
        let app = try UIFixtures.newApp()
        await app.start()
        let setup = SetupModel(app: app, hf: FakeHF())
        setup.step = .files
        setup.workdir = try UIFixtures.file("not-a-folder")
        await setup.next(app)
        #expect(setup.step == .files && app.phase == .setup && app.alert != nil)
    }

    @Test func droppingAPhotoAtTheEndOpensGenerateWithIt() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        let setup = SetupModel(app: app, hf: FakeHF())
        setup.chosen = setup.cards(app).first { $0.id == "test-cube" }
        setup.step = .done
        let photo = try UIFixtures.file("mug.png")
        setup.drop([photo], app)
        #expect(app.phase == .ready && app.section == .generate)
        #expect(app.generate.current == TaskRef(recipe: "test-cube", task: "image_to_3d") && app.generate.files == [photo])
    }
}
