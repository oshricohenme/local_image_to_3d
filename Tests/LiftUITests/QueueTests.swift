import Foundation
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

    @Test func aFinishedBarSaysTheStepIsStillWorking() {
        #expect(Format.stage(nil, fraction: nil) == "Starting…")
        #expect(Format.stage("Sampling texture SLat", fraction: 0.5) == "Sampling texture SLat")
        #expect(Format.stage("Sampling texture SLat", fraction: 1) == "Sampling texture SLat done · still working…")
    }

    @Test func theLiveLineIsTheNewestNonEmptyOne() {
        #expect(Format.lastLine("Loading\nSampling:  50%|#  | 1/2\rSampling: 100%|##| 2/2\n\n") == "Sampling: 100%|##| 2/2")
        #expect(Format.lastLine("a\n[Lift] Still working: no new output for 2 min (CPU 85%)\n") == "[Lift] Still working: no new output for 2 min (CPU 85%)")
        #expect(Format.lastLine("") == "")
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

@Suite struct JobPhotosTests {
    @Test func aJobShowsItsPhotosAndAFolderItsImages() async throws {
        let lift = try await UIFixtures.lift()
        var v = try await lift.jobsSubmit(UIFixtures.cube(try UIFixtures.file("chair.png").path)).accepted()
        #expect(JobPhotos.paths(v).map { URL(filePath: $0).pathExtension } == ["png"])

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["b.jpg", "a.PNG", "notes.txt"] { try Data().write(to: folder.appending(path: name)) }
        v.steps[0].inputs = ["views": folder.path, "prompt": "a chair"]
        #expect(JobPhotos.paths(v).map { URL(filePath: $0).lastPathComponent } == ["a.PNG", "b.jpg"])
    }
}
