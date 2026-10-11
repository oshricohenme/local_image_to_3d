import Foundation
import Testing
@testable import LiftCore

/// A Test Cube variant whose model takes 1.5 s to load (set through shim env), so a job can be caught
/// while its worker is still loading. Installed for real once.
actor SlowLoadCubeFixture {
    static let shared = SlowLoadCubeFixture()
    private var lift: Lift?

    func get() async throws -> Lift {
        if let lift { return lift }
        let bundle = try Fixtures.tempDir()
        try BundledRecipes.copy(Fixtures.devRecipes, to: bundle)
        let yaml = bundle.appending(path: "test-cube/recipe.yaml")
        let text = try String(contentsOf: yaml, encoding: .utf8)
            .replacingOccurrences(of: #"shim: { env: { TEST_CUBE_SHIM: "on" } }"#, with: #"shim: { env: { TEST_CUBE_SHIM: "on", TEST_CUBE_LOAD_DELAY: "1.5" } }"#)
        try text.write(to: yaml, atomically: true, encoding: .utf8)
        let lift = try await Lift.open(LiftConfig(workdir: try Fixtures.tempDir(), workerRuntime: Fixtures.workerRuntime, bundledRecipes: bundle,
                                                  homebrewPrefix: "/nonexistent-homebrew", rosettaPrefix: "/nonexistent-rosetta",
                                                  housekeepingInterval: .milliseconds(200), heartbeatSeconds: 0.2,
                                                  hfToken: { nil }, hfHub: try Fixtures.tempDir(), weightsMetadata: FakeMetadata()))
        _ = try await lift.settingsSet("dev_recipes", .bool(true))
        let model = try await lift.modelsInstall("test-cube", confirm: true, wait: true).value
        guard case .installed = model?.status else { throw LiftError.invalidState("slow test-cube install failed: \(String(describing: model?.status))") }
        self.lift = lift
        return lift
    }
}

@Suite(.serialized, .timeLimit(.minutes(10))) struct SlowLoadCubeTests {
    func cube() throws -> StepRequest {
        StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": try Fixtures.image()])
    }

    /// Chosen behaviour: a job cancelled while its worker loads kills that worker (it was loading only for
    /// this job, one job per worker); the job never runs and the next job gets a fresh worker.
    @Test func cancellingWhileTheWorkerLoadsKillsItAndTheJobNeverRuns() async throws {
        let lift = try await SlowLoadCubeFixture.shared.get()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()])).accepted().job.id
        #expect(try await eventually { try await lift.jobsGet(id).job.state == .loading })
        let worker = try #require(await lift.workersList().first { $0.job == id })
        #expect(try await lift.jobsCancel(id, confirm: true).value?.job.state == .cancelled)
        #expect(try await eventually(3) { await lift.workersList().allSatisfy { $0.id != worker.id } })
        try await Task.sleep(for: .seconds(2))
        #expect(!FileManager.default.fileExists(atPath: lift.config.workdir.appending(path: "jobs/\(id)/steps/0/cube.glb").path))
        let next = try await lift.jobsWait(try await lift.jobsSubmit(SubmitRequest(steps: [try cube()])).accepted().job.id, timeout: .seconds(60))
        #expect(next.job.state == .succeeded && next.steps[0].workerId != worker.id)
    }
}
