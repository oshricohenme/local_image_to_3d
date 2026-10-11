import Foundation
import Testing
@testable import LiftCore

/// A bundle with only the Test Cube (dev-recipes/ also holds the real recipes).
func cubeOnlyBundle() throws -> URL {
    let b = try Fixtures.tempDir()
    try FileManager.default.copyItem(at: Fixtures.devRecipes.appending(path: "test-cube"), to: b.appending(path: "test-cube"))
    try FileManager.default.createDirectory(at: b.appending(path: "shared"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: Fixtures.devRecipes.appending(path: "shared/substitutes.yaml"), to: b.appending(path: "shared/substitutes.yaml"))
    return b
}

/// A bundle with the Test Cube and `weighted`, a copy of it that needs one Hugging Face file.
func weightedBundle() throws -> URL {
    let b = try cubeOnlyBundle()
    let cube = try String(contentsOf: Fixtures.devRecipes.appending(path: "test-cube/recipe.yaml"), encoding: .utf8)
    _ = try writeRecipe(cube.replacingOccurrences(of: "id: test-cube", with: "id: weighted")
        .replacingOccurrences(of: "resources:", with: "weights:\n  - { repo: org/weights }\nresources:"), id: "weighted", in: b)
    return b
}

@Suite struct CommandTests {
    let commit = String(repeating: "c", count: 40)

    @Test func riskyCommandsChangeNothingWithoutConfirm() async throws {
        let runner = FakeRunner()
        let meta = FakeMetadata()
        meta.set("org/weights", .success(RepoSnapshot(repo: "org/weights", revision: "main", commit: commit, files: [RemoteFile(path: "w.bin", size: 2048)])))
        let lift = try await Fixtures.lift(runner, bundle: try weightedBundle(), metadata: meta)
        #expect(try await lift.modelsInstall("test-cube").impact?.contains("Test Cube") == true)
        let weighted = try #require(try await lift.modelsInstall("weighted").impact)
        #expect(weighted.contains("org/weights@main") && weighted.contains("2 KB"))
        #expect(try await lift.modelsReinstall("test-cube").impact != nil)
        #expect(try await lift.modelsSetPin("test-cube", commit: String(repeating: "a", count: 40)).impact != nil)
        #expect(try await lift.settingsGet().pinOverrides.isEmpty)
        #expect(try await lift.modelsUninstall("test-cube").impact?.contains("stay in the Hugging Face cache") == true)
        #expect(try await lift.systemInstallPrereqs().impact?.contains("install native Homebrew") == true)
        #expect(runner.commands.isEmpty)
        #expect(try await lift.modelsGet("test-cube").status == .notInstalled)
        await #expect(throws: LiftError.self) { try await lift.modelsDownloadWeights("weighted") }  // not installed
    }

    @Test func jobsWaitForVerifiedWeights() async throws {
        let meta = FakeMetadata()
        let hub = try Fixtures.tempDir()
        meta.set("org/weights", .success(RepoSnapshot(repo: "org/weights", revision: "main", commit: commit,
                                                      files: [RemoteFile(path: "w.bin", size: 3, sha256: sha256Hex(Data([1, 2, 3])))])))
        let lift = try await Fixtures.lift(FakeRunner(), searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path],
                                           bundle: try weightedBundle(), metadata: meta, hub: hub)
        // A fake install: no `hf` in the venv, so the download fails and verification finds the file missing.
        let model = try await lift.modelsInstall("weighted", confirm: true, wait: true).value
        #expect(model?.status == .weightsMissing([WeightProblem(repo: "org/weights", path: "w.bin", issue: .missing)]))
        #expect(try await lift.modelsDownloadWeights("weighted").impact?.contains("org/weights@main") == true)
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "weighted", task: "image_to_3d",
                                                                              inputs: ["image": try Fixtures.image()])])).accepted().job.id
        #expect(try await eventually { try await lift.jobsGet(id).job.waitReason == .weightsUnverified })
        try writeHFCache(hub: hub, repo: "org/weights", commit: commit, files: ["w.bin": Data([1, 2, 3])], lfs: ["w.bin"])  // the user downloaded it
        #expect(try await lift.modelsVerifyWeights("weighted").state == .ok)
        #expect(try await lift.modelsGet("weighted").status == .installed(commit: nil))
        // Verified, so the job leaves the queue. Its fake venv has no python, so the worker can't start: the
        // step must say why (M4), not just "exit 137".
        #expect(try await eventually { try await lift.jobsGet(id).job.state == .failed })
        #expect(try await lift.jobsGet(id).job.error?.contains("could not start the worker") == true)
    }

    @Test func aCheckThatThrowsDoesNotBlockLaterChecks() async throws {
        let meta = FakeMetadata()
        let hub = try Fixtures.tempDir()
        meta.fail("org/weights", with: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "malformed API answer")))
        let lift = try await Fixtures.lift(FakeRunner(), searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path],
                                           bundle: try weightedBundle(), metadata: meta, hub: hub)
        _ = try await lift.modelsInstall("weighted", confirm: true, wait: true, downloadWeights: false)
        await #expect(throws: DecodingError.self) { try await lift.modelsVerifyWeights("weighted") }
        #expect(await !lift.verifying.contains("weighted"))
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "weighted", task: "image_to_3d",
                                                                              inputs: ["image": try Fixtures.image()])])).accepted().job.id
        #expect(try await eventually { try await lift.jobsGet(id).job.waitReason == .weightsUnverified })
        // The API recovers and the files are there: the background recheck must run and let the job go.
        let snap = try writeHFCache(hub: hub, repo: "org/weights", commit: commit, files: ["w.bin": Data([1])], lfs: ["w.bin"])
        meta.set("org/weights", .success(snap))
        #expect(try await eventually { try await lift.jobsGet(id).job.state != .waiting })
    }

    @Test func settingsAndResources() async throws {
        let lift = try await Fixtures.lift()
        #expect(try await lift.resourcesSet(maxSlots: 2, memoryBudgetGB: 32).maxSlots == 2)
        #expect(try await lift.resourcesGet().budgetBytes == 32_000_000_000)
        await #expect(throws: LiftError.self) { try await lift.resourcesSet(idleUnloadMinutes: -1) }
        await #expect(throws: LiftError.self) { try await lift.settingsSet("max_slots", .string("many")) }
        #expect(try await lift.settingsGet().maxSlots == 2)
    }

    @Test func developerRecipesNeedTheSetting() async throws {
        let lift = try await Fixtures.lift(bundle: try cubeOnlyBundle())
        _ = try await lift.settingsSet("dev_recipes", .bool(false))
        #expect(try await lift.modelsList().isEmpty)  // the Test Cube is the only bundled recipe so far, and it's hidden
        _ = try await lift.settingsSet("dev_recipes", .bool(true))
        #expect(try await lift.modelsList().map(\.id) == ["test-cube"])
    }

    @Test func modelsAndRecipesAreListed() async throws {
        let lift = try await Fixtures.lift(bundle: try cubeOnlyBundle())
        #expect(try await lift.modelsList().map(\.id) == ["test-cube"])
        #expect(await lift.recipesList() == [RecipeListing(id: "test-cube", name: "Test Cube", source: "bundled", state: .available, detail: nil)])
    }

    /// Recipes are the only entry point (spec §4): recipes_list shows every recipe found, and why one can't be used.
    @Test func recipesListShowsProblems() async throws {
        let b = try cubeOnlyBundle()
        _ = try writeRecipe("schema: 9\nid: future\n", id: "future", in: b)
        _ = try writeRecipe("schema: 1\nid: broken\n", id: "broken", in: b)
        let lift = try await Fixtures.lift(bundle: b)
        _ = try await lift.settingsSet("dev_recipes", .bool(false))
        let listed = Dictionary(uniqueKeysWithValues: await lift.recipesList().map { ($0.id, $0) })
        #expect(listed["test-cube"]?.state == .developerHidden)
        #expect(listed["future"]?.state == .needsNewerLift && listed["future"]?.detail?.contains("9") == true)
        #expect(listed["broken"]?.state == .invalid && listed["broken"]?.detail?.hasPrefix("recipe.yaml:") == true)
        _ = try await lift.settingsSet("dev_recipes", .bool(true))
        #expect(await lift.recipesList().first { $0.id == "test-cube" }?.state == .available)
    }
}
