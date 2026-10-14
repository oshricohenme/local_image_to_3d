import Foundation
import LiftCore
import Testing
@testable import LiftUI

@MainActor @Suite struct AppModelTests {
    @Test func opensTheWorkdirAndMirrorsTheEngine() async throws {
        let prefs = MemoryPrefs()
        let app = try await UIFixtures.app(prefs)
        defer { Task { await app.close() } }
        let workdir = try #require(app.workdir)
        #expect(app.phase == .ready && prefs.string(forKey: "workdir") == workdir.path)
        #expect(FileManager.default.fileExists(atPath: workdir.appending(path: "runtime/lift_worker/worker.py").path))
        #expect(app.models.map(\.id) == ["test-cube"] && app.generate.models == app.models)
        #expect(app.serverStatus?.port ?? 0 > 0 && app.serverStatus?.urls.mcp.hasSuffix("/mcp") == true)
        #expect(app.queue?.jobs.isEmpty == true && app.resources?.maxSlots == 1)
    }

    @Test func submitQueuesAndKeepsFieldErrorsInTheForm() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        let g = app.generate
        g.recipe = "test-cube"
        g.add([try UIFixtures.file("chair.png")])
        g.values["size"] = .float(0)  // below the recipe's min
        app.submitGenerate()
        #expect(try await eventually { g.errors.map(\.field) == ["steps[0].settings.size"] })
        #expect(g.errors(forSetting: "size", step: 0).count == 1 && g.files.count == 1)  // kept for fixing
        #expect(try await app.engine.jobsList().isEmpty)
        g.values["size"] = .float(1)
        app.submitGenerate()
        #expect(try await eventually { g.files.isEmpty && app.queue?.jobs.count == 1 })
        #expect(app.queue?.jobs[0].job.title == "chair" && app.queue?.jobs[0].job.waitReason == .modelNotInstalled)
    }

    @Test func aTooBigJobQueuesWithoutAsking() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        _ = try await app.engine.resourcesSet(memoryBudgetGB: 0.1)  // the Test Cube estimates 0.5 GB
        let g = app.generate
        g.recipe = "test-cube"
        g.add([try UIFixtures.file("a.png"), try UIFixtures.file("b.png")])
        app.submitGenerate()
        #expect(try await eventually { try await app.engine.jobsList().count == 2 && g.files.isEmpty })
        #expect(app.confirmation == nil)
    }

    @Test func aFirstInstallShowsWhoMadeTheModelFirst() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        let cube = try #require(app.models.first { $0.id == "test-cube" })
        app.install(cube)
        #expect(app.aboutBeforeInstall?.id == "test-cube" && app.confirmation == nil)
        app.continueInstall()
        #expect(try await eventually { app.confirmation != nil })  // then the install's own confirmation
        #expect(app.aboutBeforeInstall == nil && app.confirmation?.message.contains("Test Cube") == true)
        app.confirmation = nil  // cancelled: nothing installs in tests
        app.install(cube)
        #expect(try await eventually { app.confirmation != nil } && app.aboutBeforeInstall == nil)  // shown once per model
    }

    @Test func gatedCommandsAskFirstAndRunOnConfirm() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        let id = try await app.engine.jobsSubmit(UIFixtures.cube(try UIFixtures.file("a.png").path)).accepted().job.id
        app.gated { confirm in try await app.engine.jobsDelete(id, confirm: confirm) }
        #expect(try await eventually { app.confirmation != nil })
        #expect(app.confirmation?.message.contains("can't be undone") == true)
        #expect(try await app.engine.jobsList().count == 1)  // nothing changed yet
        await app.confirmation?.confirm()
        #expect(try await eventually { try await app.engine.jobsList().isEmpty })
    }

    /// A job cut short by a crash is back in the queue on launch, with nothing to answer.
    @Test func interruptedJobsGoBackInTheQueueOnLaunch() async throws {
        let prefs = MemoryPrefs()
        let first = try await UIFixtures.app(prefs)
        let workdir = try #require(first.workdir)
        let id = try await first.engine.jobsSubmit(UIFixtures.cube(try UIFixtures.file("a.png").path)).accepted().job.id
        await first.close()
        // As if the app died while the job ran.
        let store = try Store(path: workdir.appending(path: "lift.sqlite").path)
        try await store.db.write { try $0.execute(sql: "UPDATE job SET state = 'running'; UPDATE step SET state = 'running'") }
        let app = try UIFixtures.newApp(prefs)
        #expect(await app.open(workdir))
        defer { Task { await app.close() } }
        #expect(try await app.engine.jobsGet(id).job.state == .waiting)
        #expect(try await app.engine.jobsListInterrupted().isEmpty)
    }

    @Test func notifiesFinishedJobsAndNewMemoryWaits() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        let base = try await app.engine.jobsSubmit(UIFixtures.cube(try UIFixtures.file("a.png").path)).accepted()
        var waiting = base
        waiting.job.waitReason = .memory(needed: 2, free: 1)
        var done = base
        done.job.state = .succeeded
        var cancelled = base
        cancelled.job.state = .cancelled
        #expect(AppModel.events(previous: [:], current: [waiting], left: []) == [.waitingForMemory(waiting)])
        #expect(AppModel.events(previous: [base.job.id: waiting], current: [waiting], left: []).isEmpty)  // once
        #expect(AppModel.events(previous: [base.job.id: waiting], current: [], left: [done]) == [.finished(done)])
        #expect(AppModel.events(previous: [base.job.id: base], current: [], left: [cancelled]).isEmpty)
    }

    @Test func aJobIsReportedFinishedOnlyOnceItsExportIsDone() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        var exporting = try await app.engine.jobsSubmit(UIFixtures.cube(try UIFixtures.file("a.png").path)).accepted()
        exporting.job.state = .succeeded
        exporting.job.exportPending = true
        #expect(AppModel.events(previous: [:], current: [], left: [exporting]).isEmpty)
        var exported = exporting
        exported.job.exportPending = false
        exported.job.cleanedUp = true  // jobs/<id>/ is gone: Reveal must point at the export
        exported.job.exports = [try JSONDecoder().decode(ExportResult.self, from: Data(#"{"format":"glb","path":"/exports/a.glb"}"#.utf8))]
        #expect(AppModel.events(previous: [:], current: [], left: [exported]) == [.finished(exported)])
        let c = Notifier.content(.finished(exported))
        #expect(c.userInfo["path"] as? String == "/exports/a.glb" && c.body == "a.glb")
    }

    @Test func aBatchThatFailsPartwayKeepsOnlyWhatWasntQueued() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        let g = app.generate
        g.recipe = "test-cube"
        let files = [try UIFixtures.file("a.png"), try UIFixtures.file("b.png"), try UIFixtures.file("c.png")]
        g.add(files)
        try FileManager.default.removeItem(at: files[1])  // moved away after it was added
        app.submitGenerate()
        #expect(try await eventually { !g.errors.isEmpty })
        #expect(try await app.engine.jobsList().count == 1 && g.files == Array(files[1...]))
    }

    @Test func launchAtLoginFollowsTheSetting() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        var system = false
        var calls: [Bool] = []
        app.launchAtLoginEnabled = { system }
        app.applyLaunchAtLogin = { on in calls.append(on); system = on }
        _ = try await app.engine.settingsSet("launch_at_login", .bool(true))  // e.g. from HTTP or MCP
        await app.refresh()
        #expect(calls == [true] && system)
        await app.refresh()
        #expect(calls == [true])  // in step: nothing to do

        app.applyLaunchAtLogin = { _ in throw LiftError.invalidState("not allowed") }
        _ = try await app.engine.settingsSet("launch_at_login", .bool(false))
        await app.refresh()
        #expect(app.alert?.contains("not allowed") == true)
        #expect(try await eventually { app.settings.launchAtLogin == true })  // back to what the system has; no retry loop
    }

    @Test func movingTheWorkdirTakesItsDataAlong() async throws {
        let prefs = MemoryPrefs()
        let app = try await UIFixtures.app(prefs)
        defer { Task { await app.close() } }
        let old = try #require(app.workdir)
        let id = try await app.engine.jobsSubmit(UIFixtures.cube(try UIFixtures.file("a.png").path)).accepted().job.id
        let destination = try UIFixtures.tempDir().appending(path: "moved")
        app.moveWorkdir(to: destination)
        #expect(app.confirmation?.message.contains(destination.path) == true)
        #expect(FileManager.default.fileExists(atPath: old.path))  // nothing moves before the OK
        await app.confirmation?.confirm()
        #expect(app.phase == .ready && app.workdir == destination && prefs.string(forKey: "workdir") == destination.path)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(try await app.engine.jobsGet(id).job.title == "a")
    }
}
