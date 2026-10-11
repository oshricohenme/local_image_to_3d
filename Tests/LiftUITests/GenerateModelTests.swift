import Foundation
import LiftCore
import Testing
@testable import LiftUI

@MainActor @Suite struct GenerateModelTests {
    func model() async throws -> GenerateModel {
        let g = GenerateModel()
        g.models = try await UIFixtures.lift().modelsList()
        return g
    }

    @Test func chipsGroupTasksAndNoRecipeIsPickedForYou() async throws {
        let g = try await model()
        #expect(g.chips("3d").map(\.kind.label) == ["Image → 3D", "Mesh → Rigged"])
        #expect(g.chips("3d")[0].models.map(\.id) == ["test-cube"])
        #expect(g.taskCount("image") == 0 && g.chips("audio").isEmpty)
        #expect(g.kind?.label == "Image → 3D")  // the first chip is shown
        #expect(g.recipe == nil && g.current == nil && g.requests.isEmpty)  // the model is the user's choice
        g.recipe = "test-cube"
        #expect(g.current == TaskRef(recipe: "test-cube", task: "image_to_3d"))
        #expect(g.values["size"] == .float(1.0))  // defaults from the recipe's settings schema
        g.modality = "image"
        #expect(g.kind == nil && g.recipe == nil)  // nothing offers Image tasks yet
    }

    @Test func oneRequestPerFileWithTheFollowUpStep() async throws {
        let g = try await model()
        g.recipe = "test-cube"
        let a = try UIFixtures.file("a.png"), b = try UIFixtures.file("b.JPG"), mesh = try UIFixtures.file("m.glb")
        #expect(g.add([a, b, mesh, a, try UIFixtures.tempDir()]) == 2)  // only image files fit Image → 3D, once each
        #expect(g.followUps == [TaskRef(recipe: "test-cube", task: "fake_rig")])
        g.then = g.followUps[0]
        g.values["size"] = .float(2.5)
        g.priority = .high
        let requests = g.requests
        #expect(requests.count == 2)
        #expect(requests[0].steps.map(\.task) == ["image_to_3d", "fake_rig"])
        #expect(requests[0].steps[0].inputs == ["image": a.path])
        #expect(requests[0].steps[1].inputs.isEmpty)  // chained: takes step 1's output
        #expect(requests[1].steps[0].settings["size"] == .float(2.5) && requests[1].priority == .high && requests[1].source == .ui)
    }

    @Test func theBundledRecipesBecomeChips() async throws {
        let g = GenerateModel()
        let lift = try await UIFixtures.lift(bundle: UIFixtures.devRecipes)
        _ = try await lift.settingsSet("dev_recipes", .bool(false))  // as users see it: no Test Cube
        g.models = try await lift.modelsList()
        let chips = g.chips("3d")
        #expect(!g.models.contains { $0.id == "test-cube" })
        #expect(chips.first { $0.kind.label == "Image → 3D" }?.models.map(\.id).sorted() == ["pixal3d", "trellis2-mac"])
        #expect(chips.contains { $0.kind.label == "Mesh → Rigged" && $0.models.map(\.id) == ["unirig"] })
        g.recipe = "pixal3d"
        #expect(g.followUps.contains(TaskRef(recipe: "unirig", task: "rig")))  // rig what Pixal3D makes
    }

    @Test func useAsInputPrefillsTheTask() async throws {
        let g = try await model()
        g.use("/tmp/out.glb", for: TaskRef(recipe: "test-cube", task: "fake_rig"))
        #expect(g.kind?.label == "Mesh → Rigged")
        #expect(g.current == TaskRef(recipe: "test-cube", task: "fake_rig"))
        #expect(g.files == [URL(filePath: "/tmp/out.glb")])
    }
}
