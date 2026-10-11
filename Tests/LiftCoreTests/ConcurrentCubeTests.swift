import Foundation
import Testing
@testable import LiftCore

/// A Test Cube variant with `max_concurrent_per_process: 2`, a 1.5 s model load (through shim env) and an
/// `ignore_cancel` setting (a launcher that can't be interrupted, like most upstream code). Installed for real once.
actor ConcurrentCubeFixture {
    static let shared = ConcurrentCubeFixture()
    private var lift: Lift?

    func get() async throws -> Lift {
        if let lift { return lift }
        let bundle = try Fixtures.tempDir()
        try BundledRecipes.copy(Fixtures.devRecipes, to: bundle)
        let yaml = bundle.appending(path: "test-cube/recipe.yaml")
        let text = try String(contentsOf: yaml, encoding: .utf8)
            .replacingOccurrences(of: "max_concurrent_per_process: 1", with: "max_concurrent_per_process: 2")
            .replacingOccurrences(of: #"shim: { env: { TEST_CUBE_SHIM: "on" } }"#, with: #"shim: { env: { TEST_CUBE_SHIM: "on", TEST_CUBE_LOAD_DELAY: "1.5" } }"#)
            .replacingOccurrences(of: "      - { key: crash, label: Crash the worker, type: bool, default: false, group: advanced }",
                                  with: "      - { key: crash, label: Crash the worker, type: bool, default: false, group: advanced }\n      - { key: ignore_cancel, label: Ignore cancel, type: bool, default: false, group: advanced }")
        try text.write(to: yaml, atomically: true, encoding: .utf8)
        let lift = try await Lift.open(LiftConfig(workdir: try Fixtures.tempDir(), workerRuntime: Fixtures.workerRuntime, bundledRecipes: bundle,
                                                  homebrewPrefix: "/nonexistent-homebrew", rosettaPrefix: "/nonexistent-rosetta",
                                                  housekeepingInterval: .milliseconds(200), heartbeatSeconds: 0.2,
                                                  hfToken: { nil }, hfHub: try Fixtures.tempDir(), weightsMetadata: FakeMetadata()))
        _ = try await lift.settingsSet("dev_recipes", .bool(true))
        _ = try await lift.resourcesSet(maxSlots: 2)
        let model = try await lift.modelsInstall("test-cube", confirm: true, wait: true).value
        guard case .installed = model?.status, await lift.installed["test-cube"]?.resources.maxConcurrentPerProcess == 2 else {
            throw LiftError.invalidState("concurrent test-cube install failed: \(String(describing: model?.status))")
        }
        self.lift = lift
        return lift
    }
}

@Suite(.serialized, .timeLimit(.minutes(10))) struct ConcurrentCubeTests {
    func cube(_ settings: [String: SettingValue] = [:]) throws -> StepRequest {
        StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": try Fixtures.image()], settings: settings)
    }

    func noWorkers(_ lift: Lift) async throws {
        for w in await lift.workersList() { _ = try await lift.workersUnload(w.id, confirm: true) }
        #expect(try await eventually(10) { await lift.workersList().isEmpty })
    }

    /// I3: a job cancelled while its worker is still loading must never run.
    @Test func cancellingBeforeTheWorkerIsReadyMeansTheJobNeverRuns() async throws {
        let lift = try await ConcurrentCubeFixture.shared.get()
        try await noWorkers(lift)
        let a = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()])).job.id
        let b = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()])).job.id
        #expect(try await eventually {
            let (sa, sb) = (try await lift.jobsGet(a).job.state, try await lift.jobsGet(b).job.state)
            return sa == .loading && sb == .loading
        })
        #expect(try await lift.jobsCancel(b, confirm: true).value?.job.state == .cancelled)
        #expect(try await lift.jobsWait(a, timeout: .seconds(30)).job.state == .succeeded)
        try await Task.sleep(for: .seconds(1))
        #expect(!FileManager.default.fileExists(atPath: lift.config.workdir.appending(path: "jobs/\(b)/steps/0/cube.glb").path))
        #expect(await lift.workersList().allSatisfy { $0.jobs.isEmpty })
    }

    /// I4: retrying a cancelled job while the cancelled attempt still runs must record the retry's result only.
    @Test func aRetryIgnoresTheCancelledAttemptsLateResult() async throws {
        let lift = try await ConcurrentCubeFixture.shared.get()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube(["delay": .float(2), "ignore_cancel": .bool(true)])])).job.id
        #expect(try await eventually { try await lift.jobsGet(id).job.state == .running })
        #expect(try await lift.jobsCancel(id, confirm: true).value?.job.state == .cancelled)
        _ = try await lift.jobsRetry(id, settings: ["delay": .float(5)])
        let early = try await lift.jobsWait(id, timeout: .seconds(3.5))
        #expect(early.job.state != .succeeded)  // the cancelled attempt finished at ~2 s; its result isn't the retry's
        let v = try await lift.jobsWait(id, timeout: .seconds(30))
        #expect(v.job.state == .succeeded)
        #expect(try await eventually(10) { await lift.workersList().allSatisfy { $0.jobs.isEmpty } })
    }
}
