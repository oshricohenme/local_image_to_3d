import CryptoKit
import Foundation

/// Keeps `<workdir>/recipes/bundled/` in step with the recipes built into the app (spec §4, §11).
/// The first launch copies them. An app update with different recipes refreshes the copy:
/// - a top-level folder you edited (or added) is moved to `bundled-local/` first;
/// - a folder holding files Lift never writes (a `.venv`, Finder's `.DS_Store`) but otherwise unchanged is
///   moved aside to the hidden `.bundled-previous/<ms>/`;
/// - only folders made entirely of files equal to Lift's copy are deleted.
/// The fresh copy is staged with its manifest and swapped in, so the copy never exists without one.
/// The app bundle itself is only read.
public struct BundledRecipes: Sendable {
    /// Development leftovers that are never copied.
    public static let ignored: Set<String> = [".venv", "__pycache__", ".pytest_cache", ".DS_Store", manifestName]
    static let manifestName = ".lift-bundle.json"

    public struct Result: Codable, Sendable, Equatable {
        /// A fresh copy was written (first launch, or the bundle changed).
        public var copied: Bool
        /// Folders moved to `bundled-local/` because they differed from what Lift had copied.
        public var keptLocal: [String]
        /// Unchanged folders moved to `.bundled-previous/` because they held files Lift didn't write.
        public var setAside: [String] = []
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
        let fresh = try Self.digests(bundle, skipping: Self.ignored)
        let freshDigest = Self.combined(fresh)
        let manifest = (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        if manifest?.bundle == freshDigest && fm.fileExists(atPath: copyDir.path) { return Result(copied: false, keptLocal: []) }

        // Leftovers of an interrupted update: Lift's own staging folders.
        try fm.createDirectory(at: recipes, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: recipes.path) where name.hasPrefix(".bundled-staging-") {
            try fm.removeItem(at: recipes.appending(path: name))
        }
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let staging = recipes.appending(path: ".bundled-staging-\(stamp)")
        try Self.copy(bundle, to: staging)
        try JSONEncoder().encode(Manifest(bundle: freshDigest, folders: fresh)).write(to: staging.appending(path: Self.manifestName))

        var result = Result(copied: true, keptLocal: [])
        if fm.fileExists(atPath: copyDir.path) {
            let loose = try Self.digests(copyDir, skipping: Self.ignored)          // what counts as content
            let strict = try Self.digests(copyDir, skipping: [Self.manifestName])  // every file there
            for name in try fm.contentsOfDirectory(atPath: copyDir.path).sorted() where name != Self.manifestName {
                let unedited = loose[name].map { $0 == manifest?.folders[name] || $0 == fresh[name] } ?? Self.ignored.contains(name)
                if !unedited {
                    try move(name, to: localDir, asideIfTaken: true)
                    result.keptLocal.append(name)
                } else if Self.ignored.contains(name) || strict[name] != loose[name] {
                    try move(name, to: recipes.appending(path: ".bundled-previous/\(stamp)"), asideIfTaken: false)
                    result.setAside.append(name)
                }
            }
            try fm.removeItem(at: copyDir)  // only folders equal to Lift's own copy are left in it
        }
        try fm.moveItem(at: staging, to: copyDir)
        return result
    }

    /// Moves `bundled/<name>` into `dir`. With `asideIfTaken`, an older kept copy there is moved aside to
    /// a hidden `.<name>-<timestamp>`, so nothing is lost.
    func move(_ name: String, to dir: URL, asideIfTaken: Bool) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appending(path: name)
        if asideIfTaken && fm.fileExists(atPath: dest.path) {
            try fm.moveItem(at: dest, to: dir.appending(path: ".\(name)-\(Int(Date().timeIntervalSince1970 * 1000))"))
        }
        try fm.moveItem(at: copyDir.appending(path: name), to: dest)
    }

    /// SHA-256 per top-level entry, over relative paths and contents, skipping `skip` names at any depth.
    static func digests(_ root: URL, skipping skip: Set<String>) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path) where !skip.contains(name) {
            var hash = SHA256()
            for file in files(root.appending(path: name), skipping: skip) {
                hash.update(data: Data(file.relative.utf8))
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: file.url.path) {
                    hash.update(data: Data("symlink:\(target)".utf8))  // never followed: it may point anywhere
                } else {
                    hash.update(data: try Data(contentsOf: file.url))
                }
            }
            out[name] = hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    static func combined(_ digests: [String: String]) -> String {
        let text = digests.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Regular files under `url` (or `url` itself), sorted, skipping `skip` names at any depth.
    /// A symbolic link is listed as itself, not followed.
    static func files(_ url: URL, skipping skip: Set<String> = ignored) -> [(relative: String, url: URL)] {
        if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil { return [("", url)] }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return [] }
        guard isDir.boolValue else { return [("", url)] }
        let children = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        return children.filter { !skip.contains($0) }.sorted().flatMap { name in
            files(url.appending(path: name), skipping: skip).map { (name + ($0.relative.isEmpty ? "" : "/" + $0.relative), $0.url) }
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
