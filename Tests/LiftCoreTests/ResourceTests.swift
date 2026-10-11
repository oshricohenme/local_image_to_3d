import Foundation
import Testing
@testable import LiftCore

@Suite struct MemoryTests {
    @Test func footprintOfThisProcess() {
        #expect((Memory.footprint(pid: getpid()) ?? 0) > 1_000_000)
        #expect(Memory.footprint(pid: 999_999) == nil)
    }

    @Test func systemFreeIsPlausible() {
        let free = Memory.systemFree()
        #expect(free > 0 && free < Memory.physical)
    }
}

@Suite struct EstimatesTests {
    func recipe() throws -> Recipe {
        let folder = try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())
        guard case .ok(let r) = RecipeLoad.read(directory: folder) else { throw LiftError.invalidState("fixture") }
        return r
    }

    @Test func recipeValueAndOverrides() throws {
        let r = try recipe()
        #expect(Estimates.recipeBytes(r, settings: ["low_vram": .bool(false)]) == 18_000_000_000)
        #expect(Estimates.recipeBytes(r, settings: ["low_vram": .bool(true)]) == 12_000_000_000)
    }

    @Test func keyValuesAreCanonical() throws {
        let r = try recipe()
        #expect(Estimates.keyValues(r, settings: ["seed": .int(1), "resolution": .int(1024), "low_vram": .bool(true)])
                == #"{"low_vram":true,"resolution":1024}"#)
    }

    @Test func learnedIsMaxOfLastFive() async throws {
        let store = try Store()
        try await store.db.write { db in
            for bytes in [100, 900, 200, 300, 400, 500, 250] {  // 900 is the 6th newest: dropped
                try Estimates.record(db, recipe: "r", task: "t", keyValues: "{}", kind: .job, bytes: bytes)
            }
        }
        #expect(try await store.db.read { try Estimates.learned($0, recipe: "r", task: "t", keyValues: "{}", kind: .job) } == 500)
        #expect(try await store.db.read { try Estimates.learned($0, recipe: "r", task: "t", keyValues: "{}", kind: .load) } == nil)
    }

    @Test func needFallsBackToTheRecipe() async throws {
        let store = try Store()
        let r = try recipe()
        let s: [String: SettingValue] = ["low_vram": .bool(true), "resolution": .int(1024)]
        let keys = Estimates.keyValues(r, settings: s)
        #expect(try await store.db.read { try Estimates.need($0, recipe: r, task: "image_to_3d", settings: s) } == MemoryNeed(load: 12_000_000_000, job: 0))
        try await store.db.write { try Estimates.record($0, recipe: "pixal3d", task: "image_to_3d", keyValues: keys, kind: .load, bytes: 8_000_000_000) }
        #expect(try await store.db.read { try Estimates.need($0, recipe: r, task: "image_to_3d", settings: s) } == MemoryNeed(load: 8_000_000_000, job: 4_000_000_000))
        try await store.db.write { try Estimates.record($0, recipe: "pixal3d", task: "image_to_3d", keyValues: keys, kind: .job, bytes: 1_000_000_000) }
        #expect(try await store.db.read { try Estimates.need($0, recipe: r, task: "image_to_3d", settings: s) } == MemoryNeed(load: 8_000_000_000, job: 1_000_000_000))
    }
}
