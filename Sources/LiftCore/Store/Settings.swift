import Foundation
import GRDB

public struct RecipeSourceRef: Codable, Sendable, Equatable {
    public var name: String
    public var url: String
}

/// App settings, one `setting` row per key (snake_case key, JSON value). Missing rows mean the default.
public struct Settings: Codable, Sendable, Equatable {
    public var maxSlots = 1
    public var memoryBudgetGB = 48.0
    public var idleUnloadMinutes = 10.0
    public var devRecipes = false
    public var queuePaused = false
    /// Git recipe sources in the order they were added (first wins on duplicate ids).
    public var recipeSources: [RecipeSourceRef] = []
    /// Recipe id → commit set by `models_set_pin`.
    public var pinOverrides: [String: String] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case maxSlots = "max_slots", memoryBudgetGB = "memory_budget_gb", idleUnloadMinutes = "idle_unload_minutes"
        case devRecipes = "dev_recipes", queuePaused = "queue_paused"
        case recipeSources = "recipe_sources", pinOverrides = "pin_overrides"
    }

    /// Keys `settings_set` accepts. The rest have their own commands (queue_pause, recipes_*, models_set_pin).
    public static let userKeys: Set<String> = ["max_slots", "memory_budget_gb", "idle_unload_minutes", "dev_recipes"]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        maxSlots = try c.decodeIfPresent(Int.self, forKey: .maxSlots) ?? d.maxSlots
        memoryBudgetGB = try c.decodeIfPresent(Double.self, forKey: .memoryBudgetGB) ?? d.memoryBudgetGB
        idleUnloadMinutes = try c.decodeIfPresent(Double.self, forKey: .idleUnloadMinutes) ?? d.idleUnloadMinutes
        devRecipes = try c.decodeIfPresent(Bool.self, forKey: .devRecipes) ?? d.devRecipes
        queuePaused = try c.decodeIfPresent(Bool.self, forKey: .queuePaused) ?? d.queuePaused
        recipeSources = try c.decodeIfPresent([RecipeSourceRef].self, forKey: .recipeSources) ?? d.recipeSources
        pinOverrides = try c.decodeIfPresent([String: String].self, forKey: .pinOverrides) ?? d.pinOverrides
    }

    public var memoryBudgetBytes: Int { Int(memoryBudgetGB * 1_000_000_000) }

    func validate() throws(LiftError) {
        var errors: [FieldError] = []
        if maxSlots < 1 { errors.append(FieldError("max_slots", "must be ≥ 1")) }
        if memoryBudgetGB <= 0 { errors.append(FieldError("memory_budget_gb", "must be > 0")) }
        if idleUnloadMinutes < 0 { errors.append(FieldError("idle_unload_minutes", "must be ≥ 0")) }
        if !errors.isEmpty { throw .invalidInput(errors) }
    }

    /// Reads all rows over the defaults.
    static func load(_ db: Database) throws -> Settings {
        var object: [String: Any] = [:]
        for row in try SettingRecord.fetchAll(db) {
            object[row.key] = try JSONSerialization.jsonObject(with: Data(row.value.utf8), options: .fragmentsAllowed)
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    /// Writes every key (cheap: a handful of rows).
    func save(_ db: Database) throws {
        let data = try JSONEncoder().encode(self)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for (key, value) in object {
            let json = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
            try SettingRecord(key: key, value: String(decoding: json, as: UTF8.self)).save(db)
        }
    }

    /// Returns a copy with one user key changed; type errors and range errors throw `invalidInput`.
    public func setting(_ key: String, to value: SettingValue) throws(LiftError) -> Settings {
        guard Self.userKeys.contains(key) else {
            throw .invalidInput([FieldError(key, "unknown setting; known: \(Self.userKeys.sorted().joined(separator: ", "))")])
        }
        let updated: Settings
        do {
            var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as! [String: Any]
            object[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
            updated = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        } catch {
            throw .invalidInput([FieldError(key, "wrong type: \(value)")])
        }
        try updated.validate()
        return updated
    }
}
