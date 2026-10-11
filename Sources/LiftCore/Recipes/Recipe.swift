import Foundation
import Yams

public enum IOType: String, Codable, Sendable, CaseIterable {
    case text, image, imageSet = "image_set", mesh, riggedMesh = "rigged_mesh", video, audio

    /// Whether a step whose first input is `self` can follow a step that outputs `output` (spec §4).
    public func accepts(_ output: IOType) -> Bool {
        output == self || (self == .mesh && output == .riggedMesh)
    }
}

public enum SettingType: String, Codable, Sendable {
    case int, float, bool, `enum`, string, path
}

public struct SettingDef: Codable, Sendable, Equatable {
    public var key: String
    public var label: String
    public var type: SettingType
    public var options: [SettingValue]?
    public var `default`: SettingValue?
    public var min: Double?
    public var max: Double?
    public var help: String?
    public var group: String?
}

public struct TaskInput: Codable, Sendable, Equatable {
    public var name: String
    public var type: IOType
}

public struct RecipeTask: Codable, Sendable, Equatable {
    public var id: String
    public var modality: String
    public var label: String
    public var inputs: [TaskInput]
    public var output: IOType
    /// Informational (`module:function` inside repo/); the launcher decides how to call upstream.
    public var entry: String?
    public var settings: [SettingDef]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        modality = try c.decode(String.self, forKey: .modality)
        label = try c.decode(String.self, forKey: .label)
        inputs = try c.decode([TaskInput].self, forKey: .inputs)
        output = try c.decode(IOType.self, forKey: .output)
        entry = try c.decodeIfPresent(String.self, forKey: .entry)
        settings = try c.decodeIfPresent([SettingDef].self, forKey: .settings) ?? []
    }
}

/// `recipe.yaml`, schema v1 (spec §4), plus `shim`, `brew`, `stages`, `developer` and `weights[].revision`
/// (see the plan's schema notes).
public struct Recipe: Codable, Sendable, Equatable {
    public static let supportedSchema = 1

    public struct Platform: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable { case supported, unsupported }
        public var status: Status
        public var reason: String?
    }

    /// A Hugging Face model repo the recipe needs, at a branch, tag or commit.
    public struct Weight: Codable, Sendable, Equatable {
        public var repo: String
        public var revision: String
        public var gated: Bool
        /// Only these files of the repo (exact paths), when upstream uses a few of many; nil means the whole repo.
        public var files: [String]?

        public init(repo: String, revision: String = "main", gated: Bool = false, files: [String]? = nil) {
            self.repo = repo
            self.revision = revision
            self.gated = gated
            self.files = files
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            repo = try c.decode(String.self, forKey: .repo)
            revision = try c.decodeIfPresent(String.self, forKey: .revision) ?? "main"
            gated = try c.decodeIfPresent(Bool.self, forKey: .gated) ?? false
            files = try c.decodeIfPresent([String].self, forKey: .files)
        }
    }

    /// `shim:`, merged with what the substitutes add into the `LIFT_SHIM` JSON.
    public struct Shim: Codable, Sendable, Equatable {
        public var aliases: [String: String]
        public var standins: [String]
        /// Named `lift_shim` runtime patches, e.g. `transformers_fa2_to_sdpa`.
        public var patches: [String]
        public var env: [String: String]

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
            standins = try c.decodeIfPresent([String].self, forKey: .standins) ?? []
            patches = try c.decodeIfPresent([String].self, forKey: .patches) ?? []
            env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        }
    }

    public struct MemoryOverride: Codable, Sendable, Equatable {
        public var when: [String: SettingValue]
        public var memoryGB: Double
        enum CodingKeys: String, CodingKey { case when, memoryGB = "memory_gb" }
    }

    public struct Resources: Codable, Sendable, Equatable {
        public var memoryGB: Double
        public var memoryKeys: [String]
        public var memoryOverrides: [MemoryOverride]
        public var diskGB: Double

        enum CodingKeys: String, CodingKey {
            case memoryGB = "memory_gb", memoryKeys = "memory_keys", memoryOverrides = "memory_overrides"
            case diskGB = "disk_gb"
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            memoryGB = try c.decode(Double.self, forKey: .memoryGB)
            memoryKeys = try c.decodeIfPresent([String].self, forKey: .memoryKeys) ?? []
            memoryOverrides = try c.decodeIfPresent([MemoryOverride].self, forKey: .memoryOverrides) ?? []
            diskGB = try c.decodeIfPresent(Double.self, forKey: .diskGB) ?? 5
        }
    }

    /// `errors:` — a plain-language message for a known failure (principle 4). `match` is a regular
    /// expression tried against the step's error and log tail; the raw error stays in the log.
    public struct ErrorMessage: Codable, Sendable, Equatable {
        public var match: String
        public var message: String
    }

    public struct StagePattern: Codable, Sendable, Equatable {
        /// Python `re` syntax; named groups `name`, `pct`, or `n` + `total`.
        public var pattern: String
    }

    public var schema: Int
    public var id: String
    public var name: String
    public var publisher: String?
    public var license: String?
    public var homepage: String?
    /// One or two plain sentences: what the model is good at and its limits.
    public var description: String?
    public var repo: String?
    public var commit: String?
    public var python: String
    public var platform: Platform
    public var install: [String]
    public var substitutes: [String]
    /// Present: install `lift_shim` + its `.pth` and set `LIFT_SHIM` for the worker. Absent: no shim.
    public var shim: Shim?
    /// Native Homebrew packages (e.g. `libusb`); their `lib/` goes on the worker's `DYLD_FALLBACK_LIBRARY_PATH`.
    public var brew: [String]
    /// The install builds Metal shaders, so it needs the Metal Toolchain (`xcodebuild -downloadComponent MetalToolchain`).
    public var metalToolchain: Bool
    public var weights: [Weight]
    /// Who made it and under which licenses (spec §4a). Required: a recipe without it doesn't load.
    public var attribution: Attribution
    public var errors: [ErrorMessage]
    /// Developer-only (the Test Cube): hidden unless the `dev_recipes` setting or `LIFT_DEV_RECIPES=1` is on.
    public var developer: Bool
    public var resources: Resources
    public var stages: [StagePattern]
    public var tasks: [RecipeTask]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = try c.decode(Int.self, forKey: .schema)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        license = try c.decodeIfPresent(String.self, forKey: .license)
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        repo = try c.decodeIfPresent(String.self, forKey: .repo)
        commit = try c.decodeIfPresent(String.self, forKey: .commit)
        python = try c.decodeIfPresent(String.self, forKey: .python) ?? "3.11"
        platform = try c.decodeIfPresent(Platform.self, forKey: .platform) ?? Platform(status: .supported, reason: nil)
        install = try c.decodeIfPresent([String].self, forKey: .install) ?? []
        substitutes = try c.decodeIfPresent([String].self, forKey: .substitutes) ?? []
        shim = try c.decodeIfPresent(Shim.self, forKey: .shim)
        brew = try c.decodeIfPresent([String].self, forKey: .brew) ?? []
        metalToolchain = try c.decodeIfPresent(Bool.self, forKey: .metalToolchain) ?? false
        weights = try c.decodeIfPresent([Weight].self, forKey: .weights) ?? []
        guard let attribution = try c.decodeIfPresent(Attribution.self, forKey: .attribution) else {
            throw DecodingError.dataCorruptedError(forKey: .attribution, in: c,
                debugDescription: "attribution is required: who made it, where it comes from and its license (spec §4a)")
        }
        self.attribution = attribution
        errors = try c.decodeIfPresent([ErrorMessage].self, forKey: .errors) ?? []
        developer = try c.decodeIfPresent(Bool.self, forKey: .developer) ?? false
        resources = try c.decode(Resources.self, forKey: .resources)
        stages = try c.decodeIfPresent([StagePattern].self, forKey: .stages) ?? []
        tasks = try c.decode([RecipeTask].self, forKey: .tasks)
    }

    enum CodingKeys: String, CodingKey {
        case schema, id, name, publisher, license, homepage, description, repo, commit, python, platform, install, substitutes, shim, brew
        case metalToolchain = "metal_toolchain", weights, attribution, errors, developer, resources, stages, tasks
    }

    public func task(_ id: String) -> RecipeTask? { tasks.first { $0.id == id } }

    /// The recipe's plain message for a failure, if one of its `errors` matches the error or the log tail.
    public func plainError(_ error: String, log: [String] = []) -> String? {
        let text = ([error] + log).joined(separator: "\n")
        return errors.first { text.range(of: $0.match, options: .regularExpression) != nil }?.message
    }
}

/// The outcome of reading one recipe folder.
public enum RecipeLoad: Sendable, Equatable {
    case ok(Recipe)
    case needsNewerLift(id: String, schema: Int)
    case invalid(String)

    /// `matchFolder: false` for a model's installed copy, which lives in `models/<id>/recipe/`.
    public static func read(directory: URL, matchFolder: Bool = true) -> RecipeLoad {
        let file = directory.appending(path: "recipe.yaml")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return .invalid("cannot read \(file.path)")
        }
        struct Header: Decodable { var schema: Int; var id: String }
        do {
            let header = try YAMLDecoder().decode(Header.self, from: text)
            if header.schema > Recipe.supportedSchema {
                return .needsNewerLift(id: header.id, schema: header.schema)
            }
            let recipe = try YAMLDecoder().decode(Recipe.self, from: text)
            let problems = recipe.problems(folder: directory, matchFolder: matchFolder)
            return problems.isEmpty ? .ok(recipe) : .invalid(problems.joined(separator: "; "))
        } catch {
            return .invalid("recipe.yaml: \(error)")
        }
    }
}
