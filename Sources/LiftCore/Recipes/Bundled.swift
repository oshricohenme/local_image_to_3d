import CryptoKit
import Foundation

/// Keeps `<workdir>/recipes/bundled/` in step with the recipes built into the app (spec §4, §11).
/// The first launch copies them. An app update with different recipes refreshes the copy, and any
/// top-level folder you edited (or added) is moved to `bundled-local/` first, never deleted.
/// The app bundle itself is only read.
public struct BundledRecipes: Sendable {
    /// Development leftovers that never belong in the copy.
    public static let ignored: Set<String> = [".venv", "__pycache__", ".pytest_cache", ".DS_Store", manifestName]
    static let manifestName = ".lift-bundle.json"

    public struct Result: Codable, Sendable, Equatable {
        /// A fresh copy was written (first launch, or the bundle changed).
        public var copied: Bool
        /// Folders moved to `bundled-local/` because they differed from what Lift had copied.
        public var keptLocal: [String]
    }

    struct Manifest: Codable {
        var bundle: String
        var folders: [String: String]
    }

    let bundle: URL
    let recipes: URL

    public init(bundle: URL, recipes: URL) {
        self.bundle = bundle
        self.recipes = recipes
    }

    public var copyDir: URL { recipes.appending(path: "bundled") }
    public var localDir: URL { recipes.appending(path: "bundled-local") }
    var manifestURL: URL { copyDir.appending(path: Self.manifestName) }

    public func sync() throws -> Result {
        let fm = FileManager.default
        let fresh = try Self.digests(bundle)
        let freshDigest = Self.combined(fresh)
        let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        if manifest?.bundle == freshDigest { return Result(copied: false, keptLocal: []) }

        var kept: [String] = []
        if fm.fileExists(atPath: copyDir.path) {
            for (name, digest) in try Self.digests(copyDir) where digest != manifest?.folders[name] {
                try keep(name)
                kept.append(name)
            }
            try fm.removeItem(at: copyDir)  // only unedited copies Lift made are left in it
        }
        try Self.copy(bundle, to: copyDir)
        try JSONEncoder().encode(Manifest(bundle: freshDigest, folders: fresh)).write(to: manifestURL)
        return Result(copied: true, keptLocal: kept.sorted())
    }

    /// Moves `bundled/<name>` to `bundled-local/<name>`. An older kept copy is moved aside to a hidden
    /// `.<name>-<timestamp>`, so nothing is lost.
    func keep(_ name: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: localDir, withIntermediateDirectories: true)
        let dest = localDir.appending(path: name)
        if fm.fileExists(atPath: dest.path) {
            try fm.moveItem(at: dest, to: localDir.appending(path: ".\(name)-\(Int(Date().timeIntervalSince1970 * 1000))"))
        }
        try fm.moveItem(at: copyDir.appending(path: name), to: dest)
    }

    /// SHA-256 per top-level entry, over relative paths and contents, skipping `ignored`.
    static func digests(_ root: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where !ignored.contains(name) {
            var hash = SHA256()
            for file in files(root.appending(path: name)) {
                hash.update(data: Data(file.relative.utf8))
                hash.update(data: try Data(contentsOf: file.url))
            }
            out[name] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    static func combined(_ digests: [String: String]) -> String {
        let text = digests.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Regular files under `url` (or `url` itself), sorted, skipping `ignored` names at any depth.
    static func files(_ url: URL) -> [(relative: String, url: URL)] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [("", url)] }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return children.filter { !ignored.contains($0) }.sorted().flatMap { name in
            files(url.appending(path: name)).map { (name + ($0.relative.isEmpty ? "" : "/" + $0.relative), $0.url) }
        }
    }

    static func copy(_ from: URL, to: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: to, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: from.path) where !ignored.contains(name) {
            for file in files(from.appending(path: name)) {
                let dest = to.appending(path: name + (file.relative.isEmpty ? "" : "/" + file.relative))
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file.url, to: dest)
            }
        }
    }
}
