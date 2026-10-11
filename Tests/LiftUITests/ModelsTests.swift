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
}
