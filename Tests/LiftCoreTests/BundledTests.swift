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

    /// Every file under `dir` whose content is `text`.
    func find(_ text: String, under dir: URL) -> [String] {
        let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return all.filter { (try? String(contentsOf: $0, encoding: .utf8)) == text }.map(\.path)
    }

    /// I7a: files Lift never writes (a user's .venv, Finder's .DS_Store) are never deleted, and don't count as edits.
    @Test func aUserVenvInsideTheCopySurvivesAnUpdate() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir()
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        _ = try sync.sync()
        let venv = sync.copyDir.appending(path: "a/.venv/bin/python")
        try FileManager.default.createDirectory(at: venv.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "user venv".write(to: venv, atomically: true, encoding: .utf8)
        try "finder".write(to: sync.copyDir.appending(path: ".DS_Store"), atomically: true, encoding: .utf8)
        try "b2".write(to: b.appending(path: "b/recipe.yaml"), atomically: true, encoding: .utf8)  // the app update
        let r = try sync.sync()
        #expect(r.copied && r.keptLocal.isEmpty)  // not an edit: no bundled-local copy shadowing updates
        #expect(find("user venv", under: recipes).count == 1)
        #expect(find("finder", under: recipes).count == 1)
        #expect(try read(sync.copyDir.appending(path: "a/recipe.yaml")) == "a1")
        #expect(try read(sync.copyDir.appending(path: "b/recipe.yaml")) == "b2")
    }

    /// I7b: a missing manifest (crash, or deleted) must not turn unchanged folders into "edits".
    @Test func aMissingManifestDoesNotMoveUnchangedFolders() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir()
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        _ = try sync.sync()
        try FileManager.default.removeItem(at: sync.copyDir.appending(path: ".lift-bundle.json"))
        #expect(try sync.sync().keptLocal.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sync.localDir.path))
        try "b2".write(to: b.appending(path: "b/recipe.yaml"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: sync.copyDir.appending(path: ".lift-bundle.json"))
        #expect(try sync.sync().keptLocal == ["b"])  // old b matches neither a manifest nor the bundle: kept, never lost
        #expect(try read(sync.copyDir.appending(path: "a/recipe.yaml")) == "a1")
    }

    /// I7b: an update interrupted after staging leaves the old copy usable; the next open finishes it.
    @Test func anInterruptedUpdateIsFinishedOnTheNextOpen() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir()
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        _ = try sync.sync()
        let stale = recipes.appending(path: ".bundled-staging-1/a")  // what a crash mid-update leaves
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try "half".write(to: stale.appending(path: "recipe.yaml"), atomically: true, encoding: .utf8)
        try "b2".write(to: b.appending(path: "b/recipe.yaml"), atomically: true, encoding: .utf8)
        #expect(try sync.sync() == .init(copied: true, keptLocal: []))
        #expect(try read(sync.copyDir.appending(path: "b/recipe.yaml")) == "b2")
        #expect(FileManager.default.fileExists(atPath: sync.copyDir.appending(path: ".lift-bundle.json").path))
        #expect(!FileManager.default.fileExists(atPath: recipes.appending(path: ".bundled-staging-1").path))
    }

    @Test func aSymlinkIntoTheHomeFolderIsNotFollowedOrDeleted() throws {
        let b = try bundle(), recipes = try Fixtures.tempDir(), outside = try Fixtures.tempDir()
        try "precious".write(to: outside.appending(path: "keep.txt"), atomically: true, encoding: .utf8)
        let sync = BundledRecipes(bundle: b, recipes: recipes)
        _ = try sync.sync()
        try FileManager.default.createSymbolicLink(at: sync.copyDir.appending(path: "a/link"), withDestinationURL: outside)
        try "b2".write(to: b.appending(path: "b/recipe.yaml"), atomically: true, encoding: .utf8)
        #expect(try sync.sync().keptLocal == ["a"])  // a new entry is an edit
        #expect(try read(outside.appending(path: "keep.txt")) == "precious")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: sync.localDir.appending(path: "a/link").path)) == outside.path)
    }
}
