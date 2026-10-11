import LiftCore
import Testing
@testable import LiftUI

@Suite struct QueueTests {
    @Test func dragBecomesAMoveTarget() {
        let ids = ["a", "b", "c"]
        #expect(QueueOrder.target(ids, from: 0, to: 3) == .after("c"))
        #expect(QueueOrder.target(ids, from: 0, to: 2) == .before("c"))
        #expect(QueueOrder.target(ids, from: 2, to: 0) == .before("a"))
        #expect(QueueOrder.target(ids, from: 1, to: 1) == nil)
        #expect(QueueOrder.target(ids, from: 1, to: 2) == nil)  // dropped onto its own slot
        #expect(QueueOrder.target(ids, from: 5, to: 0) == nil)
    }

    @Test func waitReasonsAreFacts() {
        #expect(Format.waitReason(.memory(needed: 18_000_000_000, free: 12_500_000_000)) == "Needs 18.0 GB, 12.5 GB free")
        #expect(Format.waitReason(.noFreeSlot) == "Waiting for a free slot")
        #expect(Format.waitReason(.weightsUnverified) == "Weights not verified")
    }
}

@Suite struct QueueCreditTests {
    @Test func aJobCreditsTheModelItRuns() async throws {
        let lift = try await UIFixtures.lift()
        let v = try await lift.jobsSubmit(UIFixtures.cube(try UIFixtures.file("chair.png").path)).accepted()
        let links = Credits.links(v)
        #expect(links.map(\.text) == ["Made with Test Cube (Lift test fixture) by " + (v.attribution?.authors.joined(separator: ", ") ?? "")])
        #expect(links.first?.url == v.attribution?.homepage)
    }
}
