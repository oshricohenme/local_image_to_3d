import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// One real Lift with Test Cube installed (uv venv + trimesh + lift_shim), shared by the suite.
actor CubeFixture {
    static let shared = CubeFixture()
    private var lift: Lift?

    func get() async throws -> Lift {
        if let lift { return lift }
        // Real uv, git and Python; no Homebrew, a temp Hugging Face cache and fake weights metadata
        // (the Test Cube has no weights, and nothing in the tests may download any).
        let lift = try await Lift.open(LiftConfig(workdir: try Fixtures.tempDir(), workerRuntime: Fixtures.workerRuntime, bundledRecipes: Fixtures.devRecipes,
                                                  homebrewPrefix: "/nonexistent-homebrew", rosettaPrefix: "/nonexistent-rosetta",
                                                  housekeepingInterval: .milliseconds(200), heartbeatSeconds: 0.2,
                                                  hfToken: { nil }, hfHub: try Fixtures.tempDir(), weightsMetadata: FakeMetadata()))
        _ = try await lift.settingsSet("dev_recipes", .bool(true))
        let model = try await lift.modelsInstall("test-cube", confirm: true, wait: true).value
        guard case .installed = model?.status else {
            throw LiftError.invalidState("test-cube install failed: \(String(describing: model?.status))\n\((try? await lift.modelsInstallLog("test-cube")) ?? "")")
        }
        self.lift = lift
        return lift
    }
}

@Suite(.serialized, .timeLimit(.minutes(10))) struct CubeIntegrationTests {
    func cube(_ settings: [String: SettingValue] = [:]) throws -> StepRequest {
        // A space and non-ASCII in the name: paths travel through JSON, the shell is never involved.
        StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": try Fixtures.image(named: "my photo é.png")], settings: settings)
    }

    func run(_ lift: Lift, _ steps: [StepRequest]) async throws -> JobView {
        let id = try await lift.jobsSubmit(SubmitRequest(steps: steps)).accepted().job.id
        return try await lift.jobsWait(id, timeout: .seconds(120))
    }

    @Test func installsAndLists() async throws {
        let lift = try await CubeFixture.shared.get()
        let model = try await lift.modelsGet("test-cube")
        #expect(model.status == .installed(commit: nil))
        #expect((model.diskBytes ?? 0) > 0)
        #expect(try await lift.modelsInstallLog("test-cube").contains("installed test-cube"))
    }

    @Test func submitWaitSucceeds() async throws {
        let lift = try await CubeFixture.shared.get()
        let seen = Mutex<Set<JobState>>([])
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube(["size": .float(2)])])).accepted().job.id
        let v = try await lift.jobsWait(id, timeout: .seconds(120)) { v in _ = seen.withLock { $0.insert(v.job.state) } }
        #expect(v.job.state == .succeeded)
        let glb = try #require(v.outputs.first)
        #expect(glb.hasSuffix("/steps/0/cube.glb"))
        #expect(try Data(contentsOf: URL(filePath: glb)).prefix(4) == Data("glTF".utf8))
        #expect(v.steps[0].stage == "Generating" && v.steps[0].fraction == 1)
        #expect(seen.withLock { $0.contains(.running) })
        let log = try String(contentsOf: lift.config.workdir.appending(path: "jobs/\(id)/log.txt"), encoding: .utf8)
        #expect(log.contains("[Stage] Generating"))
        #expect(log.contains("shim env: on"))  // lift_shim + .pth + LIFT_SHIM reached the worker
    }

    @Test func chainedStepsPassOutputs() async throws {
        let lift = try await CubeFixture.shared.get()
        let v = try await run(lift, [try cube(), StepRequest(recipe: "test-cube", task: "fake_rig")])
        #expect(v.job.state == .succeeded)
        #expect(v.steps[1].inputs["mesh"] == v.steps[0].outputs.first)
        #expect(v.outputs.first?.hasSuffix("/steps/1/rigged.glb") == true)
    }

    @Test func failedJobKeepsTheWorker() async throws {
        let lift = try await CubeFixture.shared.get()
        let failed = try await run(lift, [try cube(["fail": .bool(true)])])
        #expect(failed.job.state == .failed && failed.job.error?.contains("failed on purpose") == true)
        #expect(try await run(lift, [try cube()]).job.state == .succeeded)
    }

    @Test func unicodeLineSeparatorsInAMessageDoNotHangTheJob() async throws {
        let lift = try await CubeFixture.shared.get()
        let name = "a\u{2028}b\u{2029}c\u{85}d.png"
        let step = StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": try Fixtures.image(named: name)], settings: ["fail": .bool(true)])
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [step])).accepted().job.id
        let v = try await lift.jobsWait(id, timeout: .seconds(20))
        #expect(v.job.state == .failed)  // not stuck in running because the error line got split
        #expect(v.job.error?.contains("for \(name)") == true)
    }

    @Test func crashFailsTheStepAndTheNextJobStillRuns() async throws {
        let lift = try await CubeFixture.shared.get()
        let crashed = try await run(lift, [try cube(["crash": .bool(true)])])
        #expect(crashed.job.state == .failed)
        #expect(crashed.job.error?.contains("exited with code 3") == true)
        #expect(try await run(lift, [try cube()]).job.state == .succeeded)
    }

    @Test func cancelRunningStopsTheWorker() async throws {
        let lift = try await CubeFixture.shared.get()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube(["delay": .float(60)])])).accepted().job.id
        #expect(try await eventually { try await lift.jobsGet(id).job.state == .running })
        #expect(try await lift.jobsCancel(id).impact != nil)
        #expect(try await lift.jobsCancel(id, confirm: true).value?.job.state == .cancelled)
        #expect(try await eventually(5) { await lift.workersList().allSatisfy { $0.job != id } })
        #expect(try await run(lift, [try cube()]).job.state == .succeeded)
    }

    @Test func badShimConfigFailsTheWorkerStartWithTheShimError() async throws {
        let lift = try await CubeFixture.shared.get()
        for w in await lift.workersList() { _ = try await lift.workersUnload(w.id, confirm: true) }
        #expect(try await eventually(10) { await lift.workersList().isEmpty })
        // What a recipe whose shim.patches names an unknown patch puts in LIFT_SHIM. (Installing such a
        // recipe already fails at the smoke check; this is a config that goes bad after install.)
        let shim = lift.config.workdir.appending(path: "models/test-cube/shim.json")
        let good = try String(contentsOf: shim, encoding: .utf8)
        try #"{"aliases":{},"env":{},"patches":["no_such_patch"],"standins":["flash_attn"]}"#.write(to: shim, atomically: true, encoding: .utf8)
        defer { try? good.write(to: shim, atomically: true, encoding: .utf8) }
        let v = try await run(lift, [try cube()])
        #expect(v.job.state == .failed)
        let error = v.job.error ?? ""
        #expect(error.contains("worker exited with code 1"))
        #expect(error.contains("lift_shim: unknown patch 'no_such_patch'"))  // the stderr tail, not just the exit code
    }

    /// Spec §8: cancel of a running job is an immediate SIGKILL of its worker's whole process group.
    @Test func cancelKillsTheWorkerAndItsChildrenImmediately() async throws {
        let lift = try await CubeFixture.shared.get()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube(["delay": .float(60), "grandchild": .bool(true)])])).accepted().job.id
        let log = lift.config.workdir.appending(path: "jobs/\(id)/log.txt")
        var grandchild: Int32 = 0
        #expect(try await eventually {
            let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            grandchild = text.split(separator: "\n").first { $0.hasPrefix("grandchild pid ") }.flatMap { Int32($0.dropFirst(15)) } ?? 0
            return grandchild > 0
        })
        let worker = try #require(await lift.workersList().first { $0.job == id })
        let t0 = ContinuousClock.now
        #expect(try await lift.jobsCancel(id, confirm: true).value?.job.state == .cancelled)
        #expect(try await eventually(3) { kill(worker.pid, 0) != 0 && kill(grandchild, 0) != 0 })
        #expect(ContinuousClock.now - t0 < .seconds(2))
        let next = try await run(lift, [try cube()])
        #expect(next.job.state == .succeeded && next.steps[0].workerId != worker.id)  // a fresh worker
    }

    @Test func learnsMemoryEstimates() async throws {
        let lift = try await CubeFixture.shared.get()
        _ = try await run(lift, [try cube()])
        let e = try await lift.resourcesGet().estimates.first { $0.recipe == "test-cube" && $0.task == "image_to_3d" }
        #expect((e?.loadBytes ?? 0) > 1_000_000)
        #expect(e?.jobBytes != nil)
    }

    @Test func idleWorkersAreUnloaded() async throws {
        let lift = try await CubeFixture.shared.get()
        _ = try await run(lift, [try cube()])
        _ = try await lift.resourcesSet(idleUnloadMinutes: 0.01)
        #expect(try await eventually(10) { await lift.workersList().isEmpty })
        _ = try await lift.resourcesSet(idleUnloadMinutes: 10)
    }

    @Test func workersLoadAndUnload() async throws {
        let lift = try await CubeFixture.shared.get()
        for w in await lift.workersList() { _ = try await lift.workersUnload(w.id) }
        #expect(try await eventually(10) { await lift.workersList().isEmpty })
        let w = try await lift.workersLoad("test-cube")
        #expect(try await eventually { await lift.workersList().first { $0.id == w.id }?.ready == true })
        #expect(try await lift.workersUnload(w.id).value != nil)
        #expect(try await eventually(10) { await lift.workersList().isEmpty })
    }
}
