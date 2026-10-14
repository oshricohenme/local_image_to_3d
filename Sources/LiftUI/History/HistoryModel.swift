import Foundation
import LiftCore
import Observation

public enum HistoryFilter: Hashable, Sendable, CaseIterable {
    case all, modality3d, image, music, video, audio, rigged, failed

    public var label: String {
        switch self {
        case .all: "All"
        case .modality3d: "3D"
        case .image: "Image"
        case .music: "Music"
        case .video: "Video"
        case .audio: "Audio"
        case .rigged: "Rigged"
        case .failed: "Failed"
        }
    }
}

/// History: finished jobs (kept until you delete them, spec §7), filtered by modality, output type or
/// failure, plus a title search.
@MainActor @Observable
public final class HistoryModel {
    public var filter = HistoryFilter.all
    public var text = ""
    public var selected: String?
    public private(set) var jobs: [JobView] = []

    public init() {}

    public var current: JobView? { jobs.first { $0.job.id == selected } }

    /// The LiftCore query for the filter; `rigged` is narrowed afterwards by output type.
    var query: JobFilter {
        let finished: [JobState] = [.succeeded, .failed, .cancelled]
        let text = text.isEmpty ? nil : text
        switch filter {
        case .all, .rigged: return JobFilter(states: finished, text: text)
        case .modality3d: return JobFilter(states: finished, modality: "3d", text: text)
        case .image: return JobFilter(states: finished, modality: "image", text: text)
        case .music: return JobFilter(states: finished, modality: "music", text: text)
        case .video: return JobFilter(states: finished, modality: "video", text: text)
        case .audio: return JobFilter(states: finished, modality: "audio", text: text)
        case .failed: return JobFilter(states: [.failed], text: text)
        }
    }

    public func reload(_ lift: Lift, models: [ModelView]) async throws {
        var found = try await lift.jobsList(query)
        if filter == .rigged { found = found.filter { Self.output(of: $0, models: models) == .riggedMesh } }
        if found != jobs { jobs = found }
        if selected == nil || current == nil { selected = jobs.first?.job.id }
    }

    /// What the viewer shows: the job's own first output, or once its files were cleaned up after
    /// exporting, the exported GLB (or USDZ).
    public static func viewable(_ v: JobView) -> String? {
        if !v.job.cleanedUp { return v.outputs.first }
        if let folder = v.job.exports.first(where: { $0.format == .original && $0.path != nil })?.path,
           let first = v.outputs.first {
            return URL(filePath: folder).appending(path: URL(filePath: first).lastPathComponent).path
        }
        return v.job.exports.first { $0.format == .glb && $0.path != nil }?.path ?? v.job.exports.first { $0.format == .usdz && $0.path != nil }?.path
    }

    /// The type the job's last step produces, from its recipe task.
    public static func output(of v: JobView, models: [ModelView]) -> IOType? {
        guard let last = v.steps.last else { return nil }
        return models.first { $0.id == last.recipe }?.recipe.task(last.task)?.output
    }

    /// `curl` that submits the same job again over HTTP (spec §10): the same steps, inputs (the job's
    /// copies) and settings. A chained step's first input comes from the step before, so it's left out.
    public static func curl(_ v: JobView, apiBase: String, models: [ModelView]) -> String {
        let steps: [[String: Any]] = v.steps.map { s in
            var inputs = s.inputs
            if s.idx > 0, let first = models.first(where: { $0.id == s.recipe })?.recipe.task(s.task)?.inputs.first {
                inputs[first.name] = nil
            }
            let settings = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(s.settings))) ?? [:]
            return ["recipe": s.recipe, "task": s.task, "inputs": inputs, "settings": settings]
        }
        let body: [String: Any] = ["steps": steps, "title": v.job.title, "priority": v.job.priority.rawValue]
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return "curl -X POST \(apiBase)/jobs -H 'Content-Type: application/json' -d '\(json.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
