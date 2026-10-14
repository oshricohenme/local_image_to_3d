import LiftCore
import Testing
@testable import LiftUI

@Suite struct ModelsTests {
    @Test func creditsInPlainSentences() async throws {
        let models = try await UIFixtures.lift(bundle: UIFixtures.devRecipes).modelsList()
        let pixal = try #require(models.first { $0.id == "pixal3d" }).recipe.attribution
        #expect(Credits.restrictions(pixal).contains("RMBG-2.0 by BRIA AI is licensed CC-BY-NC-4.0: non-commercial."))
        #expect(Credits.madeWith(pixal).hasPrefix("Made with Pixal3D by Dong-Yang Li, "))
        let cube = try #require(models.first { $0.id == "test-cube" }).recipe.attribution
        #expect(Credits.restrictions(cube).isEmpty)
    }
}
