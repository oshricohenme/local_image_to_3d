import Foundation
import Testing
@testable import LiftCore

extension InstallerTests {
    @Test func preparesAssetsAfterCopyingTheRecipeAndBeforeMarkingInstalled() async throws {
        let entry = try source(pixalYAML.replacingOccurrences(of: "schema: 1", with: "schema: 2") + "\nprepare: [python prepare-assets.py]\n")
        let runner = FakeRunner()
        let inst = try installer(runner)
        runner.on("python prepare-assets.py", effect: {
            #expect(FileManager.default.fileExists(atPath: inst.installedRecipeDir("pixal3d").appending(path: "launcher.py").path))
            #expect(inst.installedRecipe("pixal3d") == nil)
        })
        try await inst.install(entry, pin: nil, onLine: { _ in })
        let command = try #require(runner.commands.first { $0.display == "python prepare-assets.py" })
        #expect(command.environment["HF_TOKEN"] == "hf_x" && command.environment["HF_HUB_CACHE"] == "/hf/hub")
        #expect(command.environment["HF_HUB_DISABLE_XET"] == "1" && command.ownProcessGroup)
        #expect(command.workingDirectory == inst.dir("pixal3d").path)
        #expect(runner.displays.suffix(2).first == "python prepare-assets.py")
        #expect(inst.installedRecipe("pixal3d") != nil)
        let changed = try source(pixalYAML + "\nprepare: [python changed-assets.py]\n")
        #expect(!inst.refreshRecipe(changed, pin: nil))
    }

    @Test func failedPreparationNeverMarksTheModelInstalled() async throws {
        let entry = try source(pixalYAML + "\nprepare: [python prepare-assets.py]\n")
        let runner = FakeRunner()
        runner.on("python prepare-assets.py", code: 1, lines: ["missing codec"])
        let inst = try installer(runner)
        await #expect(throws: LiftError.self) { try await inst.install(entry, pin: nil, onLine: { _ in }) }
        #expect(inst.installedRecipe("pixal3d") == nil)
        #expect(!runner.displays.contains { $0.contains("lift_worker --check") })
    }
}

extension BundledRecipeTests {
    @Test func everyMediaInstallIncludesItsPreparationAndSharedAdapter() async throws {
        for e in Self.catalog.entries.values where !e.recipe.prepare.isEmpty {
            let runner = FakeRunner()
            let inst = try installer(runner)
            try await inst.install(e, pin: nil, onLine: { _ in })
            let prep = try #require(runner.commands.first { $0.display == e.recipe.prepare[0] })
            #expect(prep.ownProcessGroup && prep.environment["HF_HUB_DISABLE_XET"] == "1")
            #expect(runner.commands.first { $0.display.contains("LIFT_SHARED_DIR/media") }?.environment["LIFT_SHARED_DIR"] == e.shared.path)
            #expect(runner.displays.last?.contains("lift_worker --check") == true)
            #expect(inst.installedRecipe(e.recipe.id) != nil)
        }
    }
}

extension CommandTests {
    @Test func mediaInstallExplainsPreparationAndCannotSilentlyOverrideDownloadFalse() async throws {
        let runner = FakeRunner()
        let lift = try await Fixtures.lift(runner)
        let impact = try #require(try await lift.modelsInstall("yue2").impact)
        #expect(impact.contains("prepares model assets") && impact.contains("non-commercial"))
        await #expect(throws: LiftError.self) { _ = try await lift.modelsInstall("yue2", confirm: true, downloadWeights: false) }
        #expect(runner.commands.isEmpty)
    }

    @Test func mediaJobsDefaultToOriginalExports() async throws {
        let lift = try await Fixtures.lift()
        let folder = try Fixtures.tempDir()
        _ = try await lift.settingsSet("export_dir", .string(folder.path))
        let v = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "kitten-tts", task: "text_to_speech", inputs: ["text": "Hello"])]), acceptMemoryWarning: true).accepted()
        #expect(v.job.export?.formats == [.original])
    }
}

extension ExporterTests {
    @Test func originalExportKeepsAllStemsAndNeverOverwritesDifferentFiles() async throws {
        let source = try Fixtures.tempDir()
        let a = source.appending(path: "target.wav"), b = source.appending(path: "residual.wav")
        try Data([1, 2, 3]).write(to: a)
        try Data([4, 5, 6]).write(to: b)
        let (folder, results) = try await export([a, b], [.original], title: "Audio")
        let output = folder.appending(path: "Audio")
        #expect(results.first?.path == output.path && results.first?.credits != nil)
        #expect(try Data(contentsOf: output.appending(path: "target.wav")) == Data([1, 2, 3]))
        #expect(try Data(contentsOf: output.appending(path: "residual.wav")) == Data([4, 5, 6]))
        try Data([7]).write(to: a)
        let (_, again) = try await export([a, b], [.original], title: "Audio", into: folder)
        #expect(again.first?.path == folder.appending(path: "Audio 2").path)
        #expect(try Data(contentsOf: folder.appending(path: "Audio 2/target.wav")) == Data([7]))
        #expect(try Data(contentsOf: output.appending(path: "target.wav")) == Data([1, 2, 3]))
    }
}
