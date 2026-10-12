import Testing
@testable import LiftCore

/// The Queue's "Stage k of N": a recipe's real phases for the job's settings, found from the stage it reports.
@Suite struct PhaseTests {
    func trellis() throws -> RecipeTask {
        guard case .ok(let r) = RecipeLoad.read(directory: Fixtures.devRecipes.appending(path: "trellis2-mac")) else {
            throw LiftError.invalidState("trellis2-mac recipe")
        }
        return try #require(r.tasks.first { $0.id == "image_to_3d" })
    }

    @Test func trellisCountsItsRealPhasesForTheSettings() throws {
        let task = try trellis()
        let textured: [String: SettingValue] = ["no_texture": .bool(false)]
        #expect(task.phase(of: "Removing the background and centring the object", settings: textured) == PhasePosition(number: 1, count: 11))
        #expect(task.phase(of: "Painting the texture", settings: textured) == PhasePosition(number: 5, count: 11))
        #expect(task.phase(of: "Baking the textures on the GPU (2048x2048)", settings: textured)?.number == 8)
        #expect(task.phase(of: "Writing the OBJ file (12 vertices; no progress bar)", settings: textured) == PhasePosition(number: 11, count: 11))
        let shapeOnly: [String: SettingValue] = ["no_texture": .bool(true)]
        #expect(task.phase(of: "Saving the 3D file with vertex colours", settings: shapeOnly) == PhasePosition(number: 8, count: 9))
        #expect(task.phase(of: "Writing the OBJ file (12 vertices; no progress bar)", settings: shapeOnly) == PhasePosition(number: 9, count: 9))
    }

    @Test func aStageOutsideTheListOrARecipeWithoutPhasesHasNoCount() throws {
        #expect(try trellis().phase(of: "Generating the 3D model (pipeline 512, seed 1)", settings: [:]) == nil)
        #expect(try trellis().phase(of: nil, settings: [:]) == nil)
    }
}
