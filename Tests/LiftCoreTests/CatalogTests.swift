import Foundation
import Testing
@testable import LiftCore

@Suite struct CatalogTests {
    let cubeYAML = try! String(contentsOf: Fixtures.devRecipes.appending(path: "test-cube/recipe.yaml"), encoding: .utf8)

    @Test func testCubeInDevRecipesIsValid() throws {
        guard case .ok(let r) = RecipeLoad.read(directory: Fixtures.devRecipes.appending(path: "test-cube")) else {
            Issue.record("\(RecipeLoad.read(directory: Fixtures.devRecipes.appending(path: "test-cube")))")
            return
        }
        #expect(r.repo == nil && r.tasks.map(\.id) == ["image_to_3d", "fake_rig"])
    }

    @Test func firstSourceWinsAndProblemsAreListed() throws {
        let a = try Fixtures.tempDir(), b = try Fixtures.tempDir()
        _ = try writeRecipe(cubeYAML, id: "test-cube", in: a)
        _ = try writeRecipe(cubeYAML, id: "test-cube", in: b)
        _ = try writeRecipe("schema: 9\nid: future\n", id: "future", in: b)
        _ = try writeRecipe("schema: 1\nid: broken\n", id: "broken", in: b)
        try FileManager.default.createDirectory(at: b.appending(path: "shared/lift_shim"), withIntermediateDirectories: true)
        let c = Catalog.scan([RecipeSourceDir(name: "a", dir: a), RecipeSourceDir(name: "b", dir: b)], includeDeveloper: true)
        #expect(c.entries.keys.sorted() == ["test-cube"])
        #expect(c.entries["test-cube"]?.source == "a")
        #expect(c.entries["test-cube"]?.shared == a.appending(path: "shared"))
        #expect(c.problems.contains(.duplicate(id: "test-cube", kept: "a", ignored: "b")))
        #expect(c.problems.contains(.needsNewerLift(source: "b", id: "future", schema: 9)))
        #expect(c.problems.contains { if case .invalid("b", "broken", _) = $0 { true } else { false } })
    }

    /// M17: hidden folders (kept copies like `.a-123`, `.bundled-previous`) are never scanned as recipes.
    @Test func hiddenFoldersAreSkipped() throws {
        let dir = try Fixtures.tempDir()
        _ = try writeRecipe(cubeYAML, id: "test-cube", in: dir)
        try FileManager.default.copyItem(at: dir.appending(path: "test-cube"), to: dir.appending(path: ".test-cube-123"))
        let c = Catalog.scan([RecipeSourceDir(name: "bundled-local", dir: dir)], includeDeveloper: true)
        #expect(c.entries.keys.sorted() == ["test-cube"] && c.problems.isEmpty)
    }

    @Test func missingSourceFolderIsEmpty() {
        #expect(Catalog.scan([RecipeSourceDir(name: "gone", dir: URL(filePath: "/nonexistent-lift-source"))]).entries.isEmpty)
    }

    @Test func developerRecipesAreHiddenByDefault() throws {
        let source = [RecipeSourceDir(name: "bundled", dir: Fixtures.devRecipes)]
        #expect(Catalog.scan(source).entries["test-cube"] == nil)
        #expect(Catalog.scan(source, includeDeveloper: true).entries["test-cube"] != nil)
    }

    @Test func sharedFallsBackToAnotherSource() throws {
        let local = try Fixtures.tempDir()
        _ = try writeRecipe(cubeYAML, id: "test-cube", in: local)
        let c = Catalog.scan([RecipeSourceDir(name: "bundled-local", dir: local, shared: Fixtures.devRecipes.appending(path: "shared"))], includeDeveloper: true)
        #expect(c.entries["test-cube"]?.shared == Fixtures.devRecipes.appending(path: "shared"))
    }

    func recipe(_ yaml: String) throws -> Recipe {
        guard case .ok(let r) = RecipeLoad.read(directory: try writeRecipe(yaml, id: "test-cube", in: try Fixtures.tempDir())) else {
            throw LiftError.invalidState("fixture")
        }
        return r
    }

    @Test func substitutesAndTheRecipeShimMakeLIFTSHIM() throws {
        let registry = try Substitute.registry(shared: Fixtures.devRecipes.appending(path: "shared"))
        #expect(registry["flash_attn"]?.standin == "flash_attn")
        #expect(registry["spconv"]?.standin == "spconv")
        let yaml = cubeYAML.replacingOccurrences(of: "substitutes: [flash_attn]", with: "substitutes: [flash_attn, spconv]")
        let config = try #require(try ShimConfig.build(try recipe(yaml), registry: registry))
        #expect(config.json == #"{"aliases":{},"env":{"TEST_CUBE_SHIM":"on"},"patches":[],"standins":["flash_attn","spconv"]}"#)
        #expect(throws: LiftError.self) { try ShimConfig.build(try self.recipe(cubeYAML.replacingOccurrences(of: "[flash_attn]", with: "[nope]")), registry: registry) }
    }

    @Test func substituteThatNeedsTheShimRequiresShim() throws {
        let registry = try Substitute.registry(shared: Fixtures.devRecipes.appending(path: "shared"))
        let noShim = try recipe(cubeYAML.replacingOccurrences(of: "shim: { env: { TEST_CUBE_SHIM: \"on\" } }", with: ""))
        #expect(noShim.shim == nil)
        #expect(throws: LiftError.self) { try ShimConfig.build(noShim, registry: registry) }
        var none = noShim
        none.substitutes = []
        #expect(try ShimConfig.build(none, registry: registry) == nil)
    }

    @Test func sourceNames() {
        #expect(RecipeSources.name(for: "https://github.com/oshricohenme/lift-recipes.git", taken: []) == "lift-recipes")
        #expect(RecipeSources.name(for: "https://github.com/x/lift-recipes", taken: ["lift-recipes"]) == "lift-recipes-2")
    }

    @Test func cloneAndPullRunGit() async throws {
        let runner = FakeRunner()
        runner.on("pull --ff-only", code: 1)
        let root = try Fixtures.tempDir()
        let sources = RecipeSources(runner: runner, root: root, git: "/usr/bin/git", environment: [:])
        try await sources.clone(url: "https://example.com/r.git", name: "r")
        #expect(await sources.pull(name: "r") == false)
        #expect(runner.displays == ["/usr/bin/git clone --filter=blob:none https://example.com/r.git \(root.path)/r",
                                    "/usr/bin/git -C \(root.path)/r pull --ff-only"])
    }
}
