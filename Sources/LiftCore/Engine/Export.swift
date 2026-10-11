import Foundation
import GRDB

extension Lift {
    /// Exports a succeeded job's final output (spec §7, §9) and records one result per format, crediting
    /// `job.credits`. With `cleanupAfterExport`, the job's own folder (`jobs/<id>/`) is deleted once every
    /// format is copied and verified; a failed format keeps it, so nothing is lost and it can be exported again.
    func export(_ id: String, _ spec: ExportSpec) async throws {
        let v = try view(id)
        guard let dir = spec.dir, let formats = spec.formats, let outputs = v.steps.last?.outputs else { return }
        try await store.db.write { db in
            try db.execute(sql: "UPDATE job SET exportPending = 1, updatedAt = ? WHERE id = ?", arguments: [Date(), id])
        }
        let jobDir = jobsDir.appending(path: id)
        // ponytail: FBX needs a Python with bpy and UniRig's venv is the one v1 has; a recipe-declared provider if a second appears.
        let exporter = Exporter(runner: config.runner, blenderPython: installed["unirig"] != nil ? installer.venvPython("unirig") : nil)
        let (title, credits) = (v.job.title, v.job.credits)
        let results = await Task.detached {
            await exporter.export(outputs, title: title, formats: formats, credits: credits, to: URL(filePath: dir), work: jobDir.appending(path: "export"))
        }.value
        let clean = spec.cleanupAfterExport == true && results.allSatisfy { $0.error == nil }
        if clean { try? FileManager.default.removeItem(at: jobDir) }
        try await store.db.write { db in
            guard var job = try JobRecord.fetchOne(db, key: id) else { return }
            job.exports = results
            job.exportPending = false
            job.cleanedUp = job.cleanedUp || clean
            job.updatedAt = Date()
            try job.update(db)
            let detail = results.map { "\($0.format.rawValue): \($0.error ?? $0.path ?? "")" }.joined(separator: "; ")
            var e = EventRecord(id: nil, jobId: id, stepIdx: nil, at: Date(), kind: "export", detail: detail)
            try e.insert(db)
        }
    }

    /// Exports a succeeded job again (spec §9): `formats`/`dir` default to the job's own export, then the settings.
    /// Returns when every format has finished; failed formats carry their error. Never deletes the job's files.
    public func jobsExport(_ id: String, formats: [ExportFormat]? = nil, dir: String? = nil) async throws -> JobView {
        let v = try view(id)
        guard v.job.state == .succeeded else { throw LiftError.invalidState("Only a finished job can be exported; this one is \(v.job.state.rawValue).") }
        guard !v.job.cleanedUp else { throw LiftError.invalidState("This job's files were deleted after its export, so it can't be exported again.") }
        guard !v.job.exportPending else { throw LiftError.invalidState("This job is already exporting.") }
        let spec = ExportSpec(dir: dir ?? v.job.export?.dir ?? settings.exportDir,
                              formats: formats ?? v.job.export?.formats ?? settings.exportFormats,
                              cleanupAfterExport: false)
        guard spec.dir != nil else { throw LiftError.invalidInput([FieldError("dir", "no export folder: give dir or set export_dir")]) }
        guard spec.formats?.isEmpty == false else { throw LiftError.invalidInput([FieldError("formats", "at least one format is required")]) }
        try await export(id, spec)
        return try view(id)
    }
}
