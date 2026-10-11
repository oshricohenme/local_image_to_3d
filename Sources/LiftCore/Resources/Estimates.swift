import Foundation
import GRDB

public enum Estimates {
    static let gb = 1_000_000_000.0

    /// Canonical JSON of the recipe's memory_keys values in these settings, e.g. `{"low_vram":true}`.
    public static func keyValues(_ recipe: Recipe, settings: [String: SettingValue]) -> String {
        let picked = settings.filter { recipe.resources.memoryKeys.contains($0.key) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(decoding: try! encoder.encode(picked), as: UTF8.self)
    }

    /// `memory_gb`, or the first `memory_overrides` entry whose `when` all match.
    public static func recipeBytes(_ recipe: Recipe, settings: [String: SettingValue]) -> Int {
        let match = recipe.resources.memoryOverrides.first { o in
            o.when.allSatisfy { key, value in
                guard let s = settings[key] else { return false }
                return s == value || (s.number != nil && s.number == value.number)
            }
        }
        return Int((match?.memoryGB ?? recipe.resources.memoryGB) * gb)
    }

    /// Max of the last 5 samples, or nil when there are none.
    public static func learned(_ db: Database, recipe: String, task: String, keyValues: String, kind: MemorySampleRecord.Kind) throws -> Int? {
        try Int.fetchOne(db, sql: """
            SELECT MAX(bytes) FROM (SELECT bytes FROM memorySample
            WHERE recipe = ? AND task = ? AND keyValues = ? AND kind = ? ORDER BY id DESC LIMIT 5)
            """, arguments: [recipe, task, keyValues, kind.rawValue])
    }

    /// Learned values replace the recipe value once a sample exists. Without a job sample, the job part
    /// is the recipe value minus the learned load (0 when nothing is learned, so a new worker needs the recipe value).
    public static func need(_ db: Database, recipe: Recipe, task: String, settings: [String: SettingValue]) throws -> MemoryNeed {
        let keys = keyValues(recipe, settings: settings)
        let total = recipeBytes(recipe, settings: settings)
        let load = try learned(db, recipe: recipe.id, task: task, keyValues: keys, kind: .load)
        let job = try learned(db, recipe: recipe.id, task: task, keyValues: keys, kind: .job)
        return MemoryNeed(load: load ?? total, job: job ?? load.map { max(0, total - $0) } ?? 0)
    }

    public static func record(_ db: Database, recipe: String, task: String, keyValues: String, kind: MemorySampleRecord.Kind, bytes: Int) throws {
        var sample = MemorySampleRecord(id: nil, recipe: recipe, task: task, keyValues: keyValues, kind: kind, bytes: bytes, at: Date())
        try sample.insert(db)
    }
}
