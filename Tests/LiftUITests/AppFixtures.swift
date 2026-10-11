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

    /// `check` stands in for the toolchain check (every tool present by default), `hf` for Hugging Face, and the
    /// engine's weights metadata is always offline, so no test talks to the network.
    @MainActor static func newApp(_ prefs: MemoryPrefs = MemoryPrefs(), bundle: URL? = nil, check: AppModel.PrereqsCheck? = { _ in readyTools },
                                  hf: any HFAccount = FakeHF()) throws -> AppModel {
        AppModel(defaults: prefs, paths: AppPaths(bundledRecipes: try bundle ?? cubeBundle(), workerSource: workerSource, bridge: nil),
                 secrets: MemorySecretStore(), serverPort: 0, checkPrereqs: check, hf: hf, weightsMetadata: OfflineHub())
    }

    /// An app whose bundle is all of `dev-recipes/` (Pixal3D, TRELLIS.2, UniRig, Test Cube), opened on a temp workdir.
    @MainActor static func devApp(hf: any HFAccount = FakeHF()) async throws -> AppModel {
        let app = try newApp(bundle: devRecipes, hf: hf)
        #expect(await app.open(try tempDir().appending(path: "workdir")))
        return app
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

/// Every tool present: what a Mac that's ready looks like.
let readyTools = Prereqs(tools: ToolPaths(brew: "/opt/homebrew/bin/brew", git: "/usr/bin/git", uv: "/opt/homebrew/bin/uv"), metalToolchain: nil)

/// Hugging Face without the network: `users` maps keys to account names, `access` gated repos to whether they're open.
struct FakeHF: HFAccount {
    var users: [String: String] = [:]
    var access: [String: Bool] = [:]
    var bytes: Int? = nil

    func whoami(token: String) async throws -> String? { users[token] }
    func canAccess(repo: String, token: String) async throws -> Bool { users[token] != nil && access[repo] == true }
    func size(of weights: [Recipe.Weight]) async -> Int? { bytes }
}

/// The engine's Hugging Face file lists, always offline: install confirmations say "an unknown amount".
struct OfflineHub: WeightsMetadata {
    func snapshot(repo: String, revision: String) async throws -> RepoSnapshot { throw WeightsMetadataError.offline }
}
