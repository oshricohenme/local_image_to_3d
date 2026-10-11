import Foundation
import Yams

/// One recipe found in a source.
public struct CatalogEntry: Sendable, Equatable {
    public var recipe: Recipe
    public var source: String
    /// The recipe folder (`recipe.yaml`, `launcher.py`, optional `files/`).
    public var directory: URL
    /// The source's `shared/` folder (`lift_shim/`, `substitutes.yaml`).
    public var shared: URL
}

public enum CatalogProblem: Codable, Sendable, Equatable {
    case invalid(source: String, folder: String, message: String)
    case needsNewerLift(source: String, id: String, schema: Int)
    case duplicate(id: String, kept: String, ignored: String)
}

/// A folder of recipe folders, and the `shared/` its recipes use.
public struct RecipeSourceDir: Sendable, Equatable {
    public var name: String
    public var dir: URL
    public var shared: URL

    public init(name: String, dir: URL, shared: URL? = nil) {
        self.name = name
        self.dir = dir
        self.shared = shared ?? dir.appending(path: "shared")
    }
}

/// All recipes across sources. Sources are scanned in order; the first to define an id wins.
/// Developer recipes (the Test Cube) are left out unless `includeDeveloper`.
public struct Catalog: Sendable {
    public var entries: [String: CatalogEntry] = [:]
    public var problems: [CatalogProblem] = []

    public init() {}

    public static func scan(_ sources: [RecipeSourceDir], includeDeveloper: Bool = false) -> Catalog {
        var catalog = Catalog()
        for source in sources {
            let (name, dir) = (source.name, source.dir)
            let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            // Hidden folders are Lift's kept copies (`.a-123`, `.bundled-previous`), never recipes (M17).
            for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where !folder.lastPathComponent.hasPrefix(".") && folder.lastPathComponent != "shared" && FileManager.default.fileExists(atPath: folder.appending(path: "recipe.yaml").path) {
                switch RecipeLoad.read(directory: folder) {
                case .ok(let recipe) where recipe.developer && !includeDeveloper:
                    continue
                case .ok(let recipe):
                    if let kept = catalog.entries[recipe.id] {
                        catalog.problems.append(.duplicate(id: recipe.id, kept: kept.source, ignored: name))
                    } else {
                        catalog.entries[recipe.id] = CatalogEntry(recipe: recipe, source: name, directory: folder, shared: source.shared)
                    }
                case .needsNewerLift(let id, let schema):
                    catalog.problems.append(.needsNewerLift(source: name, id: id, schema: schema))
                case .invalid(let message):
                    catalog.problems.append(.invalid(source: name, folder: folder.lastPathComponent, message: message))
                }
            }
        }
        return catalog
    }
}

/// One entry of `shared/substitutes.yaml`: how to provide a CUDA-only package on Apple Silicon.
public struct Substitute: Codable, Sendable, Equatable {
    /// Install commands, run in the model folder with the venv active.
    public var install: [String]
    /// `import <name>` resolves to this installed module (a `lift_shim` alias).
    public var alias: String?
    /// A `lift_shim` built-in stand-in of this name.
    public var standin: String?
    /// Named `lift_shim` runtime patches this substitute needs.
    public var patches: [String]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        install = try c.decodeIfPresent([String].self, forKey: .install) ?? []
        alias = try c.decodeIfPresent(String.self, forKey: .alias)
        standin = try c.decodeIfPresent(String.self, forKey: .standin)
        patches = try c.decodeIfPresent([String].self, forKey: .patches) ?? []
    }

    var needsShim: Bool { alias != nil || standin != nil || !patches.isEmpty }

    public static func registry(shared: URL) throws -> [String: Substitute] {
        let file = shared.appending(path: "substitutes.yaml")
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try YAMLDecoder().decode([String: Substitute].self, from: String(contentsOf: file, encoding: .utf8))
    }
}

/// The `LIFT_SHIM` contract: `{"aliases":{…},"standins":[…],"patches":[…],"env":{…}}`.
public struct ShimConfig: Codable, Sendable, Equatable {
    public var aliases: [String: String] = [:]
    public var standins: [String] = []
    public var patches: [String] = []
    public var env: [String: String] = [:]

    /// The recipe's `shim:` plus what its substitutes add. `nil` when the recipe has no `shim:`;
    /// a substitute that needs the shim then is an error.
    public static func build(_ recipe: Recipe, registry: [String: Substitute]) throws(LiftError) -> ShimConfig? {
        var config = ShimConfig()
        if let shim = recipe.shim {
            config.aliases = shim.aliases
            config.standins = shim.standins
            config.patches = shim.patches
            config.env = shim.env
        }
        for name in recipe.substitutes {
            guard let sub = registry[name] else {
                throw .prerequisite("unknown substitute \(name); add it to shared/substitutes.yaml")
            }
            if sub.needsShim && recipe.shim == nil { throw .prerequisite("substitute \(name) needs `shim:` in the recipe") }
            if let alias = sub.alias { config.aliases[name] = alias }
            if let standin = sub.standin, !config.standins.contains(standin) { config.standins.append(standin) }
            for p in sub.patches where !config.patches.contains(p) { config.patches.append(p) }
        }
        return recipe.shim == nil ? nil : config
    }

    public var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try! encoder.encode(self), as: UTF8.self)
    }
}

/// Git recipe sources under `<workdir>/recipes/<name>/`.
public struct RecipeSources: Sendable {
    let runner: any CommandRunner
    let root: URL
    let environment: [String: String]
    let git: String

    public init(runner: any CommandRunner, root: URL, git: String, environment: [String: String]) {
        self.runner = runner
        self.root = root
        self.git = git
        self.environment = environment
    }

    public func directory(_ name: String) -> URL { root.appending(path: name) }

    /// Folder name for a URL: its last path component without `.git`, made unique among `taken`.
    public static func name(for url: String, taken: Set<String>) -> String {
        var base = URL(string: url)?.deletingPathExtension().lastPathComponent ?? "source"
        if base.isEmpty || base == "/" { base = "source" }
        var name = base
        var n = 2
        while taken.contains(name) {
            name = "\(base)-\(n)"
            n += 1
        }
        return name
    }

    public func clone(url: String, name: String, onLine: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await runner.check(ShellCommand(git, ["clone", "--filter=blob:none", url, directory(name).path], environment: environment), onLine: onLine)
    }

    /// `git pull --ff-only`. On failure the checkout is untouched, so recipes keep their last good version.
    public func pull(name: String) async -> Bool {
        let code = try? await runner.run(ShellCommand(git, ["-C", directory(name).path, "pull", "--ff-only"], environment: environment), onLine: { _ in })
        return code == 0
    }

    public func remove(name: String) throws {
        try FileManager.default.removeItem(at: directory(name))
    }
}
