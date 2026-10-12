import Foundation
import GRDB
import Testing
@testable import LiftCore

extension Fixtures {
    /// A Lift on a fresh workdir with developer recipes shown, a fake runner, fake weights metadata,
    /// a temp Hugging Face cache, no Homebrew and fixed system memory. Nothing real is installed or
    /// downloaded, so jobs wait with `model_not_installed`.
    static func lift(_ runner: FakeRunner = FakeRunner(), workdir: URL? = nil, searchDirs: [String] = [],
                     bundle: URL = devRecipes, metadata: FakeMetadata = FakeMetadata(), hub: URL? = nil,
                     physical: Int = 64 << 30, readme: FakeReadmeHTTP = FakeReadmeHTTP(),
                     sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async throws -> Lift {
        let workdir = try workdir ?? tempDir()
        let seed = try Store(path: workdir.appending(path: "lift.sqlite").path)
        try await seed.db.write { try SettingRecord(key: "dev_recipes", value: "true").save($0) }  // only this row
        return try await Lift.open(LiftConfig(workdir: workdir, workerRuntime: workerRuntime, bundledRecipes: bundle,
                                              runner: runner, toolSearchDirs: searchDirs,
                                              homebrewPrefix: "/nonexistent-homebrew", rosettaPrefix: "/nonexistent-rosetta",
                                              housekeepingInterval: .seconds(3600), systemFree: { 64_000_000_000 }, physicalMemory: physical,
                                              hfToken: { nil }, hfHub: try hub ?? tempDir(), weightsMetadata: metadata,
                                              weightsRecheckInterval: .milliseconds(100), readmeHTTP: readme, sleep: sleep))
    }
}

@Suite struct EngineTests {
    func cube(_ image: String, _ settings: [String: SettingValue] = [:]) -> StepRequest {
        StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": image], settings: settings)
    }

    @Test func submitRejectsBadInputPerField() async throws {
        let lift = try await Fixtures.lift()
        let image = try Fixtures.image()
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [])).accepted() } == ["steps"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "nope", task: "x")])).accepted() } == ["steps[0].recipe"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "x")])).accepted() } == ["steps[0].task"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [self.cube(image, ["size": .int(0)])])).accepted() } == ["steps[0].settings.size"])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "image_to_3d")])).accepted() } == ["steps[0].inputs.image"])
        let wrongChain = SubmitRequest(steps: [cube(image), StepRequest(recipe: "test-cube", task: "image_to_3d")])
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(wrongChain).accepted() } == ["steps[1].task"])
        #expect(try await lift.jobsList().isEmpty)
    }

    @Test func submitCopiesInputsAndWaitsForTheModel() async throws {
        let lift = try await Fixtures.lift()
        let v = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image()), StepRequest(recipe: "test-cube", task: "fake_rig")])).accepted()
        #expect(v.job.title == "photo")
        let input = try #require(v.steps[0].inputs["image"])
        #expect(input.hasPrefix(lift.config.workdir.appending(path: "jobs/\(v.job.id)/inputs").path))
        #expect(FileManager.default.fileExists(atPath: input))
        // Defaults filled. Stored as JSON, so 1.0 reads back as 1; the worker makes float settings floats again.
        #expect(v.steps[0].settings.mapValues(\.description) == ["size": "1", "delay": "0", "fail": "false", "crash": "false", "grandchild": "false"])
        let now = try await lift.jobsGet(v.job.id)
        #expect(now.job.state == .waiting && now.job.waitReason == .modelNotInstalled)
    }

    @Test func pauseAndResume() async throws {
        let lift = try await Fixtures.lift()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image())])).accepted().job.id
        _ = try await lift.queuePause()
        #expect(try await lift.jobsGet(id).job.waitReason == .queuePaused)
        _ = try await lift.queueResume()
        #expect(try await lift.jobsGet(id).job.waitReason == .modelNotInstalled)
    }

    @Test func moveAndPriorityChangeTheOrder() async throws {
        let lift = try await Fixtures.lift()
        let image = try Fixtures.image()
        var ids: [String] = []
        for _ in 0..<3 { ids.append(try await lift.jobsSubmit(SubmitRequest(steps: [cube(image)])).accepted().job.id) }
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
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image())])).accepted().job.id
        #expect(try await lift.jobsCancel(id).value?.job.state == .cancelled)  // not running: no confirm needed
        await #expect(throws: LiftError.self) { try await lift.jobsCancel(id) }
        #expect(await fieldErrors { _ = try await lift.jobsRetry(id, settings: ["size": .int(-1)]).accepted() } == ["settings.size"])
        let retried = try await lift.jobsRetry(id, settings: ["size": .int(3)]).accepted()
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

    /// M14: a chained step whose previous step produced nothing fails with a clear message.
    @Test func aChainedStepWithNoInputFailsClearly() async throws {
        let lift = try await Fixtures.lift(searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path])
        _ = try await lift.modelsInstall("test-cube", confirm: true, wait: true)  // fake install
        _ = try await lift.queuePause()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image()), StepRequest(recipe: "test-cube", task: "fake_rig")])).accepted().job.id
        try await lift.store.db.write { db in
            try db.execute(sql: "UPDATE step SET state = 'succeeded', outputs = '[]' WHERE jobId = ? AND idx = 0", arguments: [id])
            try db.execute(sql: "UPDATE job SET currentStep = 1 WHERE id = ?", arguments: [id])
        }
        _ = try await lift.queueResume()
        let v = try await lift.jobsWait(id, timeout: .seconds(10))
        #expect(v.job.state == .failed && v.steps[1].error == "the previous step produced no output to pass on")
        #expect(await lift.workersList().isEmpty)  // no worker was started for it
    }

    @Test func forceStartNeedsConfirm() async throws {
        let lift = try await Fixtures.lift()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [cube(try Fixtures.image())])).accepted().job.id
        #expect(try await lift.jobsForceStart(id).impact != nil)
        #expect(try await lift.jobsGet(id).job.forceStart == false)
        #expect(try await lift.jobsForceStart(id, confirm: true).value?.job.forceStart == true)
    }

    @Test func interruptedJobsAfterRelaunch() async throws {
        let workdir = try Fixtures.tempDir()
        let first = try await Fixtures.lift(workdir: workdir)
        let steps = [cube(try Fixtures.image()), StepRequest(recipe: "test-cube", task: "fake_rig")]
        let a = try await first.jobsSubmit(SubmitRequest(steps: steps)).accepted().job.id
        let b = try await first.jobsSubmit(SubmitRequest(steps: steps)).accepted().job.id
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
        _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": try Fixtures.image()])])).accepted()
        await lift.housekeep()  // Duration.seconds(minutes * 60)
        let s = await lift.settingsGet()
        #expect(s.memoryBudgetGB == 48 && s.maxSlots == 1 && s.idleUnloadMinutes == 10)
    }
}

@Suite struct ImageSetSubmitTests {
    /// A bundle with `views-cube`: the Test Cube with an image_set input.
    func bundle() throws -> URL {
        let b = try Fixtures.tempDir()
        try FileManager.default.createDirectory(at: b.appending(path: "shared"), withIntermediateDirectories: true)
        let cube = try String(contentsOf: Fixtures.devRecipes.appending(path: "test-cube/recipe.yaml"), encoding: .utf8)
        _ = try writeRecipe(cube.replacingOccurrences(of: "id: test-cube", with: "id: views-cube")
            .replacingOccurrences(of: "inputs: [{ name: image, type: image }]", with: "inputs: [{ name: views, type: image_set }]"), id: "views-cube", in: b)
        return b
    }

    @Test func onlyTheListedFilesAreCopiedAndTheWorkdirParentIsRefused() async throws {
        let lift = try await Fixtures.lift(bundle: try bundle())
        let views = try Fixtures.tempDir()
        for name in ["front.png", "back.png", "transforms.json", ".DS_Store"] { try Data([1]).write(to: views.appending(path: name)) }
        let v = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "views-cube", task: "image_to_3d", inputs: ["views": views.path])])).accepted()
        let copied = try #require(v.steps[0].inputs["views"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: copied).sorted() == ["back.png", "front.png", "transforms.json"])
        let parent = lift.config.workdir.deletingLastPathComponent().path
        #expect(await fieldErrors { _ = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "views-cube", task: "image_to_3d", inputs: ["views": parent])])).accepted() }
                == ["steps[0].inputs.views"])
    }

    /// A set of photos picked one by one (Generate links them into a folder): the job keeps the photos themselves.
    @Test func linkedPhotosAreCopiedAsFiles() async throws {
        let lift = try await Fixtures.lift(bundle: try bundle())
        let photos = try Fixtures.tempDir(), views = try Fixtures.tempDir()
        try Data([7]).write(to: photos.appending(path: "front.png"))
        try FileManager.default.createSymbolicLink(at: views.appending(path: "front.png"), withDestinationURL: photos.appending(path: "front.png"))
        let v = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "views-cube", task: "image_to_3d", inputs: ["views": views.path])])).accepted()
        let copied = URL(filePath: try #require(v.steps[0].inputs["views"])).appending(path: "front.png")
        #expect(try FileManager.default.attributesOfItem(atPath: copied.path)[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: copied) == Data([7]))
    }
}


/// Test Cube "installed" through the fake runner, with a venv python that just sleeps: its worker stays
/// `loading` (and holds its reservation) until it's killed.
func fakeInstalledCube(_ lift: Lift) async throws {
    _ = try await lift.modelsInstall("test-cube", confirm: true, wait: true)
    let python = lift.config.workdir.appending(path: "models/test-cube/venv/bin/python")
    try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\nexec /bin/sleep 30\n".write(to: python, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
}

@Suite struct MemoryTests_Engine {
    func cube() throws -> StepRequest { StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": try Fixtures.image()]) }

    /// M18: the default budget is min(48, 75% of this Mac's RAM), set once at first open.
    @Test(arguments: [(16, 12.0), (32, 25.0), (128, 48.0)])
    func defaultBudgetComesFromThisMac(gib: Int, expected: Double) async throws {
        let lift = try await Fixtures.lift(physical: gib << 30)
        #expect(await lift.settingsGet().memoryBudgetGB == expected)
    }

    @Test func aChosenBudgetIsKept() async throws {
        let workdir = try Fixtures.tempDir()
        let first = try await Fixtures.lift(workdir: workdir, physical: 16 << 30)
        _ = try await first.settingsSet("memory_budget_gb", .float(14))
        await first.close()
        #expect(await (try Fixtures.lift(workdir: workdir, physical: 16 << 30)).settingsGet().memoryBudgetGB == 14)
    }

    /// Spec §8: too big is a warning, never a refusal; nothing changes until it's accepted.
    @Test func tooBigForTheBudgetWarnsThenRunsWhenAccepted() async throws {
        let lift = try await Fixtures.lift(searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path])
        try await fakeInstalledCube(lift)
        _ = try await lift.settingsSet("memory_budget_gb", .float(0.1))  // the cube needs 0.5 GB
        let warned = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()]))
        let w = try #require(warned.warning)
        #expect(w.step == 0 && w.neededGB == 0.5 && w.budgetGB == 0.1)
        #expect(w.message.contains("0.5 GB") && w.message.contains("budget"))
        #expect(try await lift.jobsList().isEmpty)  // nothing was queued
        let v = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()]), acceptMemoryWarning: true).accepted()
        #expect(v.job.memoryAccepted)
        // Over the budget and the queue is otherwise empty: it must start, never wait forever.
        #expect(try await eventually(5) { try await lift.jobsGet(v.job.id).job.state == .loading })
        _ = try await lift.jobsCancel(v.job.id, confirm: true)
    }

    @Test func tooBigForThisMacWarns() async throws {
        let lift = try await Fixtures.lift(searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path], physical: 256 << 20)  // a 256 MB Mac
        try await fakeInstalledCube(lift)
        let w = try #require(try await lift.jobsSubmit(SubmitRequest(steps: [try cube()])).warning)
        #expect(w.message.contains("this Mac has") && w.physicalGB < 0.5)
    }

    @Test func aNormalJobIsUnaffected() async throws {
        let lift = try await Fixtures.lift(searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path])
        try await fakeInstalledCube(lift)
        let v = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()])).accepted()
        #expect(!v.job.memoryAccepted)
        _ = try await lift.jobsCancel(v.job.id, confirm: true)
    }

    @Test func retryWarnsToo() async throws {
        let lift = try await Fixtures.lift(searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path])
        try await fakeInstalledCube(lift)
        _ = try await lift.queuePause()
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()])).accepted().job.id
        _ = try await lift.jobsCancel(id)
        _ = try await lift.settingsSet("memory_budget_gb", .float(0.1))
        #expect(try await lift.jobsRetry(id).warning != nil)
        #expect(try await lift.jobsGet(id).job.state == .cancelled)  // unchanged
        #expect(try await lift.jobsRetry(id, acceptMemoryWarning: true).accepted().job.memoryAccepted)
    }

    /// M18: a starting worker's estimate is reserved at once, so a second tick can't start another
    /// before the first worker has allocated anything.
    @Test func aStartingWorkerIsReservedImmediately() async throws {
        let lift = try await Fixtures.lift(searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path])
        try await fakeInstalledCube(lift)
        _ = try await lift.settingsSet("memory_budget_gb", .float(0.8))  // room for one 0.5 GB cube
        _ = try await lift.resourcesSet(maxSlots: 2)
        _ = try await lift.queuePause()
        let a = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()])).accepted().job.id
        let b = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()])).accepted().job.id
        _ = try await lift.queueResume()
        await lift.tick()
        await lift.tick()
        #expect(try await lift.jobsGet(a).job.state == .loading)
        #expect(try await lift.jobsGet(b).job.waitReason == .memory(needed: 500_000_000, free: 300_000_000))
        #expect(try await lift.resourcesGet().reservedBytes == 500_000_000)
        _ = try await lift.jobsCancel(a, confirm: true)
        _ = try await lift.jobsCancel(b)
    }
}

extension Lift {
    /// Cancel (kills the worker) and retry (a fresh worker), then deliver the killed worker's `done` as if it
    /// was read from its pipe before its exit, all in one actor turn.
    func cancelRetryThenStaleDone(_ id: String) throws -> String {
        let old = workers.values.first { $0.job?.jobId == id }!
        _ = try jobsCancel(id, confirm: true)
        _ = try jobsRetry(id).accepted()
        old.job = Assignment(jobId: id, step: 0, task: "image_to_3d", keyValues: "{}", claim: 0, sent: true)
        _ = try store.db.write { try $0.execute(sql: "UPDATE step SET state = 'running' WHERE jobId = ?", arguments: [id]) }
        try finish(old, job: id, outputs: ["/stale/cube.glb"], error: nil)
        return old.id
    }
}

@Suite struct StaleResultTests {
    /// Defence kept from the concurrency days: a result from any worker but the step's current one is discarded.
    @Test func aKilledWorkersLateResultIsNotTheRetrysResult() async throws {
        let lift = try await Fixtures.lift(searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path])
        try await fakeInstalledCube(lift)  // workers sleep in `loading`
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [StepRequest(recipe: "test-cube", task: "image_to_3d",
                                                                              inputs: ["image": try Fixtures.image()])])).accepted().job.id
        #expect(try await eventually { try await lift.jobsGet(id).job.state == .loading })
        let old = try await lift.cancelRetryThenStaleDone(id)
        let v = try await lift.jobsGet(id)
        #expect(v.steps[0].workerId != old)
        #expect(v.job.state != .succeeded && v.steps[0].outputs.isEmpty)
        // And the killed worker's exit, handled after the retry started, doesn't fail the retry.
        #expect(try await eventually { await lift.workersList().allSatisfy { $0.id != old } })
        #expect(try await lift.jobsGet(id).job.state == .loading)
        _ = try await lift.jobsCancel(id, confirm: true)
    }
}
