import Foundation
import LiftCore
import Testing
@testable import LiftUI

enum UIFixtures {
    /// The repository root (this file is Tests/LiftUITests/Support.swift).
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// The repo's `dev-recipes/`: the real recipes plus the Test Cube (what Lift.app bundles).
    static let devRecipes = root.appending(path: "dev-recipes")
    static let workerSource = root.appending(path: "python/lift_worker/src")

    /// A bundle with only the Test Cube, so tests see one known recipe.
    static func cubeBundle() throws -> URL {
        let b = try tempDir()
        let fm = FileManager.default
        try fm.copyItem(at: devRecipes.appending(path: "test-cube"), to: b.appending(path: "test-cube"))
        try fm.createDirectory(at: b.appending(path: "shared"), withIntermediateDirectories: true)
        try fm.copyItem(at: devRecipes.appending(path: "shared/substitutes.yaml"), to: b.appending(path: "shared/substitutes.yaml"))
        return b
    }

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lift-ui-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small file to drop or submit.
    static func file(_ name: String) throws -> URL {
        let url = try tempDir().appending(path: name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url
    }

    /// A Lift on a temp workdir with developer mode on (the Test Cube shown). Nothing is installed.
    static func lift(bundle: URL? = nil) async throws -> Lift {
        let lift = try await Lift.open(LiftConfig(workdir: try tempDir(), workerRuntime: workerSource,
                                                  bundledRecipes: try bundle ?? cubeBundle(), housekeepingInterval: .seconds(3600),
                                                  hfHub: try tempDir()))
        _ = try await lift.settingsSet("dev_recipes", .bool(true))
        return lift
    }
}

extension Admission {
    /// The accepted value; a memory warning fails the test.
    func accepted() throws -> T {
        guard case .accepted(let v) = self else { throw LiftError.invalidState("unexpected memory warning: \(warning!.message)") }
        return v
    }
}

/// Polls `condition` every 50 ms for up to `seconds`.
@MainActor func eventually(_ seconds: Double = 10, _ condition: @MainActor () async throws -> Bool) async throws -> Bool {
    let end = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < end {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}
