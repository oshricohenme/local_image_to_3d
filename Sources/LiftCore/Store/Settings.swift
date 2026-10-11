import Foundation
import GRDB

/// App settings, one `setting` row per key (snake_case key, JSON value). Missing rows mean the default.
public struct Settings: Codable, Sendable, Equatable {
    public var maxSlots = 1
    public var memoryBudgetGB = 48.0
    public var idleUnloadMinutes = 10.0
    public var devRecipes = false
    public var queuePaused = false
    /// Recipe id → commit set by `models_set_pin`.
    public var pinOverrides: [String: String] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case maxSlots = "max_slots", memoryBudgetGB = "memory_budget_gb", idleUnloadMinutes = "idle_unload_minutes"
        case devRecipes = "dev_recipes", queuePaused = "queue_paused"
        case pinOverrides = "pin_overrides"
    }

    /// Keys `settings_set` accepts. The rest have their own commands (queue_pause, models_set_pin).
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
        pinOverrides = try c.decodeIfPresent([String: String].self, forKey: .pinOverrides) ?? d.pinOverrides
    }

    /// Upper bounds keep every value convertible to bytes / a Duration without trapping:
    /// at most 64 slots, a 4096 GB budget and a week (10080 minutes) of idle time.
    public static let maxSlotsLimit = 64
    public static let memoryBudgetGBLimit = 4096.0
    public static let idleUnloadMinutesLimit = 10080.0

    /// Safe even for a value that slipped past validation.
    public var memoryBudgetBytes: Int {
        guard memoryBudgetGB.isFinite else { return Int(Settings().memoryBudgetGB * 1_000_000_000) }
        return Int(min(max(memoryBudgetGB, 0), Self.memoryBudgetGBLimit) * 1_000_000_000)
    }

    var problems: [FieldError] {
        var errors: [FieldError] = []
        if !(1...Self.maxSlotsLimit).contains(maxSlots) { errors.append(FieldError("max_slots", "must be 1…\(Self.maxSlotsLimit)")) }
        if !(memoryBudgetGB > 0 && memoryBudgetGB <= Self.memoryBudgetGBLimit) {
            errors.append(FieldError("memory_budget_gb", "must be > 0 and ≤ \(Self.memoryBudgetGBLimit.formatted())"))
        }
        if !(idleUnloadMinutes >= 0 && idleUnloadMinutes <= Self.idleUnloadMinutesLimit) {
            errors.append(FieldError("idle_unload_minutes", "must be 0…\(Self.idleUnloadMinutesLimit.formatted())"))
        }
        return errors
    }

    func validate() throws(LiftError) {
        let errors = problems
        if !errors.isEmpty { throw .invalidInput(errors) }
    }

    /// Reads all rows over the defaults. A row that doesn't decode or is out of range is skipped with a
    /// log line (its default stays), so a corrupt database can't stop Lift from opening.
    static func load(_ db: Database) throws -> Settings {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings())) as! [String: Any]
        var settings = Settings()
        for row in try SettingRecord.fetchAll(db) {
            var candidate = object
            guard let value = try? JSONSerialization.jsonObject(with: Data(row.value.utf8), options: .fragmentsAllowed) else {
                print("lift: ignoring unreadable setting \(row.key)=\(row.value)")
                continue
            }
            candidate[row.key] = value
            guard let data = try? JSONSerialization.data(withJSONObject: candidate),
                  let decoded = try? JSONDecoder().decode(Settings.self, from: data), decoded.problems.isEmpty else {
                print("lift: ignoring invalid setting \(row.key)=\(row.value); using the default")
                continue
            }
            object = candidate
            settings = decoded
        }
        return settings
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
