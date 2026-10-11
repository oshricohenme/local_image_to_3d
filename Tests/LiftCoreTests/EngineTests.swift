import Foundation
import GRDB
import Testing
@testable import LiftCore

extension Fixtures {
    /// A Lift on a fresh workdir with developer recipes shown, a fake runner, fake weights metadata,
    /// a temp Hugging Face cache, no Homebrew and fixed system memory. Nothing real is installed or
    /// downloaded, so jobs wait with `model_not_installed`.
    static func lift(_ runner: FakeRunner = FakeRunner(), workdir: URL? = nil, searchDirs: [String] = [],
                     bundle: URL = devRecipes, metadata: FakeMetadata = FakeMetadata(), hub: URL? = nil) async throws -> Lift {
        let workdir = try workdir ?? tempDir()
        let seed = try Store(path: workdir.appending(path: "lift.sqlite").path)
        try await seed.db.write { db in
            var s = try Settings.load(db)
            s.devRecipes = true
            try s.save(db)
        }
        return try await Lift.open(LiftConfig(workdir: workdir, workerRuntime: workerRuntime, bundledRecipes: bundle,
                                              runner: runner, toolSearchDirs: searchDirs,
                                              homebrewPrefix: "/nonexistent-homebrew", rosettaPrefix: "/nonexistent-rosetta",
                                              housekeepingInterval: .seconds(3600), systemFree: { 64_000_000_000 },
                                              hfToken: { nil }, hfHub: try hub ?? tempDir(), weightsMetadata: metadata,
                                              weightsRecheckInterval: .milliseconds(100)))
    }
}

@Suite struct EngineTests {
    func cube(_ image: String, _ settings: [String: SettingValue] = [:]) -> StepRequest {
        StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": image], settings: settings)
    }

    @Test func submitRejectsBadInputPerField() async throws {
        let lift = try await Fixtures.lift()
        let image = try Fixtures.image()
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [])) } == ["steps"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "nope", task: "x")])) } == ["steps[0].recipe"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "x")])) } == ["steps[0].task"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [self.cube(image, ["size": .int(0)])])) } == ["steps[0].settings.size"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "image_to_3d")])) } == ["steps[0].inputs.image"])
        let wrongChain = SubmitRequest(steps: [cube(image), StepRequest(recipe: "test-cube", task: "image_to_3d")])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(wrongChain) } == ["steps[1].task"])
        #expect(try await lift.jobsList().isEmpty)
    }

    @Test func submitCopiesInputsAndWaitsForTheModel() async throws {
        let lift = try await Fixtures.lift()
        let v = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image()), StepRequest(recipe: "test-cube", task: "fake_rig")]))
        #expect(v.job.title == "photo")
        let input = try #require(v.steps[0].inputs["image"])
        #expect(input.hasPrefix(lift.config.workdir.appending(path: "jobs/\(v.job.id)/inputs").path))
        #expect(FileManager.default.fileExists(atPath: input))
        // Defaults filled. Stored as JSON, so 1.0 reads back as 1; the worker makes float settings floats again.
        #expect(v.steps[0].settings.mapValues(\.description) == ["size": "1", "delay": "0", "fail": "false", "crash": "false"])
        let now = try await lift.jobsGet(v.job.id)
        #expect(now.job.state == .waiting && now.job.waitReason == .modelNotInstalled)
    }

    @Test func pauseAndResume() async throws {
        let lift = try await Fixtures.lift()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image())])).job.id
        _ = try await lift.queuePause()
        #expect(try await lift.jobsGet(id).job.waitReason == .queuePaused)
        _ = try await lift.queueResume()
        #expect(try await lift.jobsGet(id).job.waitReason == .modelNotInstalled)
    }

    @Test func moveAndPriorityChangeTheOrder() async throws {
        let lift = try await Fixtures.lift()
        let image = try Fixtures.image()
        var ids: [String] = []
        for _ in 0..<3 { ids.append(try await lift.jobsSubmit(SubmitRequest(steps: [cube(image)])).job.id) }
        func order() async throws -> [String] { try await lift.queueStatus().jobs.map(\.job.id) }
        #expect(try await order() == ids)
        _ = try await lift.jobsMove(ids[2], to: .before(ids[0]))
        #expect(try await order() == [ids[2], ids[0], ids[1]])
        _ = try await lift.jobsMove(ids[2], to: .index(2))
        #expect(try await order() == [ids[0], ids[1], ids[2]])
        _ = try await lift.jobsMove(ids[0], to: .after(ids[1]))
        #expect(try await order() == [ids[1], ids[0], ids[2]])
        _ = try await lift.jobsSetPriority(ids[2], .high)
        #expect(try await order() == [ids[2], ids[1], ids[0]])
    }

    @Test func cancelRetryAndDelete() async throws {
        let lift = try await Fixtures.lift()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image())])).job.id
        #expect(try await lift.jobsCancel(id).value?.job.state == .cancelled)  // not running: no confirm needed
        await #expect(throws: LiftError.self) { try await lift.jobsCancel(id) }
        #expect(await fieldErrors { _ = try await lift.jobsRetry(id, settings: ["size": .int(-1)]) } == ["settings.size"])
        let retried = try await lift.jobsRetry(id, settings: ["size": .int(3)])
        #expect(retried.steps[0].settings["size"]?.number == 3 && retried.job.state != .cancelled)
        #expect(try await lift.jobsDelete(id).impact != nil)
        #expect(try await lift.jobsGet(id).job.id == id)  // unconfirmed: nothing changed
        #expect(try await lift.jobsDelete(id, confirm: true).value == true)
        await #expect(throws: LiftError.notFound("job \(id)")) { try await lift.jobsGet(id) }
        #expect(!FileManager.default.fileExists(atPath: lift.config.workdir.appending(path: "jobs/\(id)").path))
    }

    @Test func firstOpenCopiesTheBundledRecipes() async throws {
        let lift = try await Fixtures.lift()
        let copy = lift.config.workdir.appending(path: "recipes/bundled")
        #expect(FileManager.default.fileExists(atPath: copy.appending(path: "test-cube/recipe.yaml").path))
        #expect(FileManager.default.fileExists(atPath: copy.appending(path: "shared/lift_shim/pyproject.toml").path))
        #expect(!FileManager.default.fileExists(atPath: copy.appending(path: "shared/lift_shim/.venv").path))
        #expect(await lift.bundleSync.copied)
        #expect(await lift.sourceDirs.map(\.name) == ["bundled"])
        #expect(!FileManager.default.fileExists(atPath: lift.config.workdir.appending(path: "models").path))  // nothing installed
    }

    @Test func forceStartNeedsConfirm() async throws {
        let lift = try await Fixtures.lift()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image())])).job.id
        #expect(try await lift.jobsForceStart(id).impact != nil)
        #expect(try await lift.jobsGet(id).job.forceStart == false)
        #expect(try await lift.jobsForceStart(id, confirm: true).value?.job.forceStart == true)
    }

    @Test func interruptedJobsAfterRelaunch() async throws {
        let workdir = try Fixtures.tempDir()
        let first = try await Fixtures.lift(workdir: workdir)
        let steps = [cube(try Fixtures.image()), StepRequest(recipe: "test-cube", task: "fake_rig")]
        let a = try await first.jobsSubmit(SubmitRequest(steps: steps)).job.id
        let b = try await first.jobsSubmit(SubmitRequest(steps: steps)).job.id
        await first.close()
        // Simulate a crash mid-run: step 0 finished, step 1 running.
        try await first.store.db.write { db in
            for id in [a, b] {
                try db.execute(sql: "UPDATE step SET state = 'succeeded', outputs = '[\"/x/cube.glb\"]' WHERE jobId = ? AND idx = 0", arguments: [id])
                try db.execute(sql: "UPDATE step SET state = 'running' WHERE jobId = ? AND idx = 1", arguments: [id])
                try db.execute(sql: "UPDATE job SET state = 'running', currentStep = 1 WHERE id = ?", arguments: [id])
            }
        }
        let lift = try await Fixtures.lift(workdir: workdir)
        #expect(try await lift.jobsListInterrupted().map(\.job.id).sorted() == [a, b].sorted())
        #expect(try await lift.jobsGet(a).steps.map(\.state) == [.succeeded, .interrupted])
        let requeued = try await lift.jobsResolveInterrupted(ids: [a], action: .requeue)
        #expect(requeued.first?.steps.map(\.state) == [.succeeded, .waiting])  // restarts from step 1
        #expect(requeued.first?.job.currentStep == 1)
        _ = try await lift.jobsResolveInterrupted(action: .discard)
        #expect(try await lift.jobsGet(b).job.state == .cancelled)
        #expect(try await lift.jobsListInterrupted().isEmpty)
    }

}

@Suite struct CorruptSettingsTests {
    @Test func outOfRangeStoredSettingsDoNotBrickLaunch() async throws {
        let workdir = try Fixtures.tempDir()
        let seed = try Store(path: workdir.appending(path: "lift.sqlite").path)
        try await seed.db.write { db in
            for (k, v) in [("memory_budget_gb", "4.8e10"), ("max_slots", "1000000"), ("idle_unload_minutes", "1e300")] {
                try SettingRecord(key: k, value: v).save(db)
            }
        }
        let lift = try await Fixtures.lift(workdir: workdir)
        _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": try Fixtures.image()])]))
        await lift.housekeep()  // Duration.seconds(minutes * 60)
        let s = await lift.settingsGet()
        #expect(s.memoryBudgetGB == 48 && s.maxSlots == 1 && s.idleUnloadMinutes == 10)
    }
}
