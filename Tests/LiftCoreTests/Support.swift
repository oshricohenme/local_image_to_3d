import Foundation
import Testing
@testable import LiftCore

enum Fixtures {
    /// The repository root (this file is Tests/LiftCoreTests/Support.swift).
    static let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let workerRuntime = root.appending(path: "python/lift_worker/src")
    static let devRecipes = root.appending(path: "dev-recipes")
    static let fixtureLauncher = root.appending(path: "python/lift_worker/tests/fixtures/launcher.py")

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

    /// A folder of empty executables with these names (stand-ins for brew, git, uv).
    static func fakeBin(_ names: [String]) throws -> URL {
        let dir = try tempDir()
        for n in names {
            let f = dir.appending(path: n)
            try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
        return dir
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

/// The `field`s of the `invalidInput` error `body` throws (empty if it doesn't throw).
func fieldErrors(_ body: () async throws -> Void) async -> [String] {
    do { try await body() } catch let LiftError.invalidInput(errors) { return errors.map(\.field) } catch { return ["unexpected \(error)"] }
    return []
}

extension Admission {
    /// The accepted value; a memory warning fails the test.
    func accepted() throws -> T {
        guard case .accepted(let v) = self else { throw LiftError.invalidState("unexpected memory warning: \(warning!.message)") }
        return v
    }
}
