import Foundation
import GRDB
import Testing
@testable import LiftCore

@Suite struct StoreTests {
    func job(_ id: String, state: JobState = .queued) -> JobRecord {
        JobRecord(id: id, title: "t", priority: .high, position: 1, source: .ui, state: state, forceStart: false,
                  currentStep: 0, createdAt: Date(timeIntervalSince1970: 1_000_000), updatedAt: Date(timeIntervalSince1970: 1_000_000))  // whole ms: SQLite keeps ms
    }

    @Test func jobAndStepRoundTripWithJSONColumns() async throws {
        let store = try Store()
        var waiting = job("a", state: .waiting)
        waiting.waitReason = .memory(needed: 10, free: 3)
        let j = waiting
        let s = StepRecord(jobId: "a", idx: 0, recipe: "r", task: "t", inputs: ["image": "/x.png"],
                           settings: ["size": .float(1.5), "seed": .int(42), "low_vram": .bool(true), "mode": .string("fast")],
                           state: .waiting, waitReason: .noFreeSlot, outputs: ["/o.glb"])
        try await store.db.write { db in
            try j.insert(db)
            try s.insert(db)
        }
        let (j2, s2) = try await store.db.read { db in
            (try JobRecord.fetchOne(db, key: "a"), try StepRecord.fetchOne(db, key: ["jobId": "a", "idx": 0]))
        }
        #expect(j2 == j)
        #expect(s2 == s)
        let raw = try await store.db.read { try String.fetchOne($0, sql: "SELECT waitReason FROM job") }
        #expect(raw?.contains(#""reason":"memory""#) == true)  // stored as JSON text
    }

    @Test func deletingAJobCascades() async throws {
        let store = try Store()
        try await store.db.write { db in
            try job("a").insert(db)
            try StepRecord(jobId: "a", idx: 0, recipe: "r", task: "t", inputs: [:], settings: [:], state: .queued, outputs: []).insert(db)
            var e = EventRecord(id: nil, jobId: "a", stepIdx: 0, at: Date(), kind: "state", detail: "queued")
            try e.insert(db)
            _ = try JobRecord.deleteOne(db, key: "a")
        }
        let counts = try await store.db.read { db in (try StepRecord.fetchCount(db), try EventRecord.fetchCount(db)) }
        #expect(counts == (0, 0))
    }

    @Test func settingsDefaultsAndRoundTrip() async throws {
        let store = try Store()
        let defaults = try await store.db.read { try Settings.load($0) }
        #expect(defaults == Settings())
        #expect(defaults.maxSlots == 1 && defaults.memoryBudgetGB == 48 && defaults.idleUnloadMinutes == 10)
        var s = defaults
        s.recipeSources = [RecipeSourceRef(name: "lift-recipes", url: "https://example.com/lift-recipes.git")]
        s.pinOverrides = ["pixal3d": String(repeating: "a", count: 40)]
        s.queuePaused = true
        let saved = s
        try await store.db.write { try saved.save($0) }
        #expect(try await store.db.read { try Settings.load($0) } == saved)
    }

    @Test func settingValidation() throws {
        let s = Settings()
        #expect(try s.setting("max_slots", to: .int(3)).maxSlots == 3)
        #expect(try s.setting("memory_budget_gb", to: .int(64)).memoryBudgetGB == 64)
        #expect(throws: LiftError.self) { try s.setting("max_slots", to: .int(0)) }
        #expect(throws: LiftError.self) { try s.setting("max_slots", to: .string("two")) }
        #expect(throws: LiftError.self) { try s.setting("queue_paused", to: .bool(true)) }  // has its own command
        #expect(throws: LiftError.self) { try s.setting("nope", to: .int(1)) }
    }

    @Test func waitReasonCoding() throws {
        for r: WaitReason in [.noFreeSlot, .memory(needed: 5, free: 1), .modelInstalling, .modelNotInstalled, .modelUnsupported, .weightsUnverified, .queuePaused] {
            #expect(try JSONDecoder().decode(WaitReason.self, from: JSONEncoder().encode(r)) == r)
        }
        #expect(String(decoding: try JSONEncoder().encode(WaitReason.noFreeSlot), as: UTF8.self) == #"{"reason":"no_free_slot"}"#)
    }
}
