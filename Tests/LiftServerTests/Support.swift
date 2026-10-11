import Foundation
import Testing

enum Fixtures {
    /// The repository root (this file is Tests/LiftServerTests/Support.swift).
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let workerRuntime = root.appending(path: "python/lift_worker/src")
    /// The bundled recipes (this repo's dev-recipes/, which includes the Test Cube).
    static let devRecipes = root.appending(path: "dev-recipes")

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "lift-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A small file to use as an image input.
    static func image(named name: String = "photo.png") throws -> String {
        let url = try tempDir().appending(path: name)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        return url.path
    }
}

/// Polls `condition` every 50 ms for up to `seconds`.
func eventually(_ seconds: Double = 20, _ condition: () async throws -> Bool) async throws -> Bool {
    let end = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < end {
        if try await condition() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return false
}
