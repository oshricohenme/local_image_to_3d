import LiftCore
import Testing
@testable import LiftUI

@MainActor @Suite struct NotifierTests {
    @Test func notificationsStateFacts() async throws {
        let lift = try await UIFixtures.lift()
        var v = try await lift.jobsSubmit(UIFixtures.cube(try UIFixtures.file("chair.png").path)).accepted()
        v.job.waitReason = .memory(needed: 18_000_000_000, free: 9_000_000_000)
        let wait = Notifier.content(.waitingForMemory(v))
        #expect(wait.title == "Waiting for memory: chair" && wait.body == "Needs 18.0 GB, 9.0 GB free")
        v.job.state = .failed
        v.job.error = "worker exited with code 1"
        let failed = Notifier.content(.finished(v))
        #expect(failed.title == "Failed: chair" && failed.body == "worker exited with code 1" && failed.userInfo.isEmpty)
    }
}
