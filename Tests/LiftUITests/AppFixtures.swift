import Foundation
import LiftCore
import LiftServer
import Testing
@testable import LiftUI

/// Preferences in memory, so tests never write the user's defaults.
final class MemoryPrefs: PreferenceStore {
    var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { values[key] as? String }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
}

extension UIFixtures {
    static func paths() throws -> AppPaths { AppPaths(bundledRecipes: try cubeBundle(), workerSource: workerSource, bridge: nil) }

    @MainActor static func newApp(_ prefs: MemoryPrefs = MemoryPrefs()) throws -> AppModel {
        AppModel(defaults: prefs, paths: try paths(), secrets: MemorySecretStore(), serverPort: 0)
    }

    /// An AppModel opened on its own temp workdir with the Test Cube shown; the server on any free port.
    @MainActor static func app(_ prefs: MemoryPrefs = MemoryPrefs()) async throws -> AppModel {
        let app = try newApp(prefs)
        #expect(await app.open(try tempDir().appending(path: "workdir")))
        _ = try await app.engine.settingsSet("dev_recipes", .bool(true))
        await app.refresh()
        return app
    }

    static func cube(_ image: String) -> SubmitRequest {
        SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": image])])
    }
}
