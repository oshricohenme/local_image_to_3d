import Foundation
import LiftCore

/// The commands whose arguments need more than a straight pass-through, or whose LiftCore signature is still
/// changing (submit, retry, recipes). HTTP (API.swift) and MCP (Tools.swift) both call these.
struct Shared: Sendable {
    let lift: Lift

    func submit(_ wire: SubmitWire, files: [String: URL] = [:], inputs: Inputs, source: JobSource) async throws -> Admission<JobView> {
        defer { inputs.cleanUp() }
        return try await lift.jobsSubmit(inputs.resolve(wire, files: files, source: source), acceptMemoryWarning: wire.acceptMemoryWarning ?? false)
    }

    func retry(_ id: String, settings: [String: SettingValue]?, acceptMemoryWarning: Bool) async throws -> Admission<JobView> {
        try await lift.jobsRetry(id, settings: settings, acceptMemoryWarning: acceptMemoryWarning)
    }

    func recipes() async -> RecipesOut { RecipesOut(recipes: await lift.recipesList()) }

    func move(_ id: String, before: String?, after: String?, index: Int?) async throws -> JobView {
        let targets = [before.map(MoveTarget.before), after.map(MoveTarget.after), index.map(MoveTarget.index)].compactMap { $0 }
        guard targets.count == 1, let target = targets.first else {
            throw LiftError.invalidInput([FieldError("before", "give exactly one of before, after or index")])
        }
        return try await lift.jobsMove(id, to: target)
    }

    func wait(_ id: String, seconds: Double?, onProgress: @escaping @Sendable (JobView) -> Void = { _ in }) async throws -> JobView {
        try await lift.jobsWait(id, timeout: .seconds(min(max(seconds ?? 30, 0), 3600)), onProgress: onProgress)
    }

    /// An output file of the job, by file name.
    func output(_ id: String, file: String) async throws -> URL {
        let job = try await lift.jobsGet(id)
        guard let path = job.output(named: file) else { throw LiftError.notFound("output \(file) of job \(id)") }
        return URL(filePath: path)
    }
}

