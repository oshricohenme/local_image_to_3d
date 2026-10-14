import LiftCore
import Testing
@testable import LiftUI

@Suite struct CreditsTests {
    @Test func theMetalToolchainIsOfferedOnlyWhenARecipeNeedsIt() async throws {
        #expect(AppModel.needsMetalToolchain(try await UIFixtures.lift().modelsList()) == false)  // the Test Cube alone
        #expect(AppModel.needsMetalToolchain(try await UIFixtures.lift(bundle: UIFixtures.devRecipes).modelsList()))  // Pixal3D, TRELLIS.2
    }

    @Test func creditsListEveryBundledProjectOnce() async throws {
        let models = try await UIFixtures.lift(bundle: UIFixtures.devRecipes).modelsList()
        let projects = CreditsView.attributions(models).map(\.project)
        #expect(projects == projects.sorted() && Set(projects).count == projects.count)
        #expect(projects.count == Set(models.map(\.recipe.attribution.project)).count && projects.count >= 4)
    }
}
