import Foundation
import Testing
@testable import LiftCore

/// Export after a real Test Cube run (same serialized suite and shared install as CubeIntegrationTests).
extension CubeIntegrationTests {
    func submit(_ lift: Lift, export: ExportSpec?, title: String = "Cube export") async throws -> JobView {
        let id = try await lift.jobsSubmit(SubmitRequest(steps: [try cube()], title: title, export: export)).accepted().job.id
        return try await lift.jobsWait(id, timeout: .seconds(120))
    }

    @Test func exportsEveryFormatAndAFailedFormatKeepsTheJobFiles() async throws {
        let lift = try await CubeFixture.shared.get()
        let dir = try Fixtures.tempDir()
        let v = try await submit(lift, export: ExportSpec(dir: dir.path, formats: [.glb, .usdz, .obj, .fbx], cleanupAfterExport: true))
        #expect(v.job.state == .succeeded && !v.job.exportPending)  // jobs_wait waited for the export
        #expect(v.job.exports.map(\.format) == [.glb, .usdz, .obj, .fbx])
        #expect(v.job.exports.prefix(3).allSatisfy { $0.error == nil })
        #expect(v.job.exports[3].error?.contains("install UniRig") == true)  // no UniRig in this workdir
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                == ["Cube export", "Cube export.credits.txt", "Cube export.glb", "Cube export.usdz"])
        #expect(v.job.exports[1].credits == dir.appending(path: "Cube export.credits.txt").path)
        #expect(try String(contentsOf: dir.appending(path: "Cube export.credits.txt"), encoding: .utf8).hasPrefix("Test Cube (Lift test fixture) by Lift (MIT), run with Lift"))
        let glb = try #require(v.outputs.first)
        #expect(!v.job.cleanedUp && FileManager.default.fileExists(atPath: glb))
    }

    @Test func cleanupDeletesOnlyTheJobFolderAfterAVerifiedCopy() async throws {
        let lift = try await CubeFixture.shared.get()
        let dir = try Fixtures.tempDir()
        let v = try await submit(lift, export: ExportSpec(dir: dir.path, formats: [.glb], cleanupAfterExport: true))
        #expect(v.job.cleanedUp && v.job.exports.first?.error == nil)
        #expect(!FileManager.default.fileExists(atPath: lift.config.workdir.appending(path: "jobs/\(v.job.id)").path))
        #expect(v.attribution?.project == "Test Cube (Lift test fixture)" && v.job.credits.count == 1)  // credits survive the cleanup
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "Cube export.glb").path))
        #expect(try await lift.jobsGet(v.job.id).job.state == .succeeded)  // the record stays
        await #expect(throws: LiftError.self) { _ = try await lift.jobsRetry(v.job.id) }
        await #expect(throws: LiftError.self) { _ = try await lift.jobsExport(v.job.id, formats: [.obj]) }
    }

    @Test func settingsAreTheDefaultsAndReExportAddsFormats() async throws {
        let lift = try await CubeFixture.shared.get()
        let dir = try Fixtures.tempDir()
        _ = try await lift.settingsSet("export_dir", .string(dir.path))
        _ = try await lift.settingsSet("export_formats", .string("glb, obj"))
        let v = try await submit(lift, export: nil, title: "Defaults")
        #expect(v.job.export == ExportSpec(dir: dir.path, formats: [.glb, .obj], cleanupAfterExport: false))
        #expect(v.job.exports.map(\.path) == [dir.appending(path: "Defaults.glb").path, dir.appending(path: "Defaults").path])
        let again = try await lift.jobsExport(v.job.id, formats: [.usdz])
        #expect(again.job.exports.map(\.path) == [dir.appending(path: "Defaults.usdz").path])
        _ = try await lift.settingsSet("export_dir", .string(""))
        #expect(await lift.settingsGet().exportDir == nil)
        let none = try await submit(lift, export: nil, title: "No folder")
        #expect(none.job.export == nil && none.job.exports.isEmpty)  // no export folder chosen: nothing exported
    }

    @Test func formatsWithoutAnyFolderAreRejectedAtSubmit() async throws {
        let lift = try await CubeFixture.shared.get()
        let errors = await fieldErrors {
            _ = try await lift.jobsSubmit(SubmitRequest(steps: [try self.cube()], export: ExportSpec(formats: [.glb])))
        }
        #expect(errors == ["export.dir"])
    }
}

@Suite struct ExportResumeTests {
    /// A quit or crash between "succeeded" and the end of its export leaves exportPending; the next open finishes it.
    @Test func anExportCutShortByAQuitRunsAtTheNextOpen() async throws {
        let workdir = try Fixtures.tempDir()
        let exportDir = try Fixtures.tempDir()
        let glb = try Fixtures.cubeGLB(in: try Fixtures.tempDir())
        let store = try Store(path: workdir.appending(path: "lift.sqlite").path)
        let now = Date()
        try await store.db.write { db in
            try JobRecord(id: "j1", title: "Resumed", priority: .normal, position: 1, source: .ui, state: .succeeded, forceStart: false,
                          currentStep: 0, createdAt: now, updatedAt: now, finishedAt: now,
                          export: ExportSpec(dir: exportDir.path, formats: [.glb], cleanupAfterExport: false), exportPending: true,
                          credits: [try attribution(cubeAttributionJSON)]).insert(db)
            try StepRecord(jobId: "j1", idx: 0, recipe: "test-cube", task: "image_to_3d", inputs: [:], settings: [:],
                           state: .succeeded, outputs: [glb.path]).insert(db)
        }
        let lift = try await Fixtures.lift(workdir: workdir)
        let v = try await lift.jobsWait("j1", timeout: .seconds(20))
        #expect(!v.job.exportPending && v.job.exports == [ExportResult(format: .glb, path: exportDir.appending(path: "Resumed.glb").path)])
        #expect(v.attribution?.credit == "Test Cube by Lift (MIT)")
    }

    /// A running export reads (and may delete) jobs/<id>/, so Retry and Delete wait for it to finish.
    @Test func retryAndDeleteAreRefusedWhileExporting() async throws {
        let workdir = try Fixtures.tempDir()
        let lift = try await Fixtures.lift(workdir: workdir)
        let now = Date()
        try await lift.store.db.write { db in
            try JobRecord(id: "j1", title: "Exporting", priority: .normal, position: 1, source: .ui, state: .succeeded, forceStart: false,
                          currentStep: 0, createdAt: now, updatedAt: now, finishedAt: now, exportPending: true, credits: []).insert(db)
            try StepRecord(jobId: "j1", idx: 0, recipe: "test-cube", task: "image_to_3d", inputs: [:], settings: [:],
                           state: .succeeded, outputs: []).insert(db)
        }
        await #expect(throws: LiftError.self) { _ = try await lift.jobsRetry("j1") }
        await #expect(throws: LiftError.self) { _ = try await lift.jobsDelete("j1", confirm: true) }
        #expect(try await lift.jobsGet("j1").job.exportPending)
    }
}
