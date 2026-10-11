import Foundation
import Testing
@testable import LiftCore

@Suite struct BundledTests {
    /// A fake app bundle: two recipe folders and shared/, with dev leftovers that must not be copied.
    func bundle() throws -> URL {
        let b = try Fixtures.tempDir()
        for (path, text) in ["a/recipe.yaml": "a1", "b/recipe.yaml": "b1", "shared/substitutes.yaml": "s1",
                             "shared/lift_shim/.venv/huge": "x", "a/__pycache__/x.pyc": "x"] {
            let url = b.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        return b
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    @Test func firstLaunchCopiesWithoutDevLeftovers() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir()
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        #expect(try sync.sync() == .init(copied: true, keptLocal: []))
        #expect(try read(sync.copyDir.appending(path: "a/recipe.yaml")) == "a1")
        #expect(!FileManager.default.fileExists(atPath: sync.copyDir.appending(path: "shared/lift_shim/.venv").path))
        #expect(!FileManager.default.fileExists(atPath: sync.copyDir.appending(path: "a/__pycache__").path))
        #expect(try sync.sync() == .init(copied: false, keptLocal: []))  // same bundle: nothing to do
    }

    @Test func appUpdateRefreshesAndKeepsEdits() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir()
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        _ = try sync.sync()
        try "a-edited".write(to: sync.copyDir.appending(path: "a/recipe.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: sync.copyDir.appending(path: "mine"), withIntermediateDirectories: true)
        try "m".write(to: sync.copyDir.appending(path: "mine/recipe.yaml"), atomically: true, encoding: .utf8)
        #expect(try sync.sync() == .init(copied: false, keptLocal: []))  // edits alone don't trigger a refresh
        try "b2".write(to: b.appending(path: "b/recipe.yaml"), atomically: true, encoding: .utf8)  // the app update
        #expect(try sync.sync() == .init(copied: true, keptLocal: ["a", "mine"]))
        #expect(try read(sync.copyDir.appending(path: "a/recipe.yaml")) == "a1")
        #expect(try read(sync.copyDir.appending(path: "b/recipe.yaml")) == "b2")
        #expect(try read(sync.localDir.appending(path: "a/recipe.yaml")) == "a-edited")
        #expect(try read(sync.localDir.appending(path: "mine/recipe.yaml")) == "m")
        #expect(try read(b.appending(path: "a/recipe.yaml")) == "a1")  // the bundle is only read
    }

    @Test func anOlderKeptCopyIsMovedAsideNotReplaced() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir()
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        _ = try sync.sync()
        for (edit, update) in [("first edit", "b2"), ("second edit", "b3")] {
            try edit.write(to: sync.copyDir.appending(path: "a/recipe.yaml"), atomically: true, encoding: .utf8)
            try update.write(to: b.appending(path: "b/recipe.yaml"), atomically: true, encoding: .utf8)
            _ = try sync.sync()
        }
        #expect(try read(sync.localDir.appending(path: "a/recipe.yaml")) == "second edit")
        let aside = try #require(try FileManager.default.contentsOfDirectory(atPath: sync.localDir.path).first { $0.hasPrefix(".a-") })
        #expect(try read(sync.localDir.appending(path: "\(aside)/recipe.yaml")) == "first edit")
    }
}
