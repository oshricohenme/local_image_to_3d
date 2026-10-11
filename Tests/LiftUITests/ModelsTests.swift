import LiftCore
import Testing
@testable import LiftUI

@Suite struct ModelsTests {
    @Test func recipesAreGroupedByTheModalitiesOfTheirTasks() async throws {
        let models = try await UIFixtures.lift().modelsList()
        let groups = ModelGroups.by(models)
        #expect(groups.map(\.modality) == ["3d", "image", "video", "audio"])
        #expect(groups[0].models.map(\.id) == ["test-cube"] && groups[1].models.isEmpty)
    }

    @Test func creditsInPlainSentences() async throws {
        let models = try await UIFixtures.lift(bundle: UIFixtures.devRecipes).modelsList()
        let pixal = try #require(models.first { $0.id == "pixal3d" }).recipe.attribution
        #expect(Credits.restrictions(pixal).contains("RMBG-2.0 by BRIA AI is licensed CC-BY-NC-4.0: non-commercial."))
        #expect(Credits.madeWith(pixal).hasPrefix("Made with Pixal3D by Dong-Yang Li, "))
        let cube = try #require(models.first { $0.id == "test-cube" }).recipe.attribution
        #expect(Credits.restrictions(cube).isEmpty)
    }
}
