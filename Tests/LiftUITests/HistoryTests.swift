import Foundation
@testable import LiftCore
import Testing
@testable import LiftUI

@MainActor @Suite struct HistoryTests {
    @Test func filtersMapToQueries() {
        let h = HistoryModel()
        #expect(h.query.states == [.succeeded, .failed, .cancelled] && h.query.modality == nil)
        h.filter = .modality3d
        #expect(h.query.modality == "3d")
        h.filter = .failed
        h.text = "chair"
        #expect(h.query.states == [.failed] && h.query.text == "chair")
    }

    @Test func viewerFollowsTheFileType() {
        #expect(ViewerKind.of("/x/a.GLB") == .mesh && ViewerKind.of("a.usdz") == .mesh)
        #expect(ViewerKind.of("a.webp") == .image && ViewerKind.of("a.mov") == .video && ViewerKind.of("a.wav") == .audio)
        #expect(ViewerKind.of("rigged.fbx") == .none)
    }

    @Test func aCleanedUpJobShowsItsExportedModel() {
        let at = Date()
        var job = JobRecord(id: "j", title: "t", priority: .normal, position: 1, source: .ui, state: .succeeded, forceStart: false,
                            currentStep: 0, createdAt: at, updatedAt: at)
        let step = StepRecord(jobId: "j", idx: 0, recipe: "test-cube", task: "image_to_3d", inputs: [:], settings: [:], state: .succeeded,
                              outputs: ["/w/jobs/j/steps/0/cube.glb"])
        #expect(HistoryModel.viewable(JobView(job: job, steps: [step])) == "/w/jobs/j/steps/0/cube.glb")
        job.cleanedUp = true
        job.exports = [ExportResult(format: .obj, path: "/e/t"), ExportResult(format: .glb, path: "/e/t.glb")]
        #expect(HistoryModel.viewable(JobView(job: job, steps: [step])) == "/e/t.glb")  // the job's own copy is gone
        job.exports = [ExportResult(format: .fbx, path: "/e/t.fbx")]
        #expect(HistoryModel.viewable(JobView(job: job, steps: [step])) == nil)
    }

    @Test func retryStepTargetsTheFirstUnfinishedStep() async throws {
        let models = try await UIFixtures.lift(bundle: UIFixtures.devRecipes).modelsList()
        let at = Date()
        let job = JobRecord(id: "j", title: "t", priority: .normal, position: 1, source: .ui, state: .failed, forceStart: false,
                            currentStep: 1, createdAt: at, updatedAt: at)
        let done = StepRecord(jobId: "j", idx: 0, recipe: "pixal3d", task: "image_to_3d", inputs: [:], settings: [:], state: .succeeded, outputs: [])
        let failed = StepRecord(jobId: "j", idx: 1, recipe: "unirig", task: "rig", inputs: [:], settings: [:], state: .failed, outputs: [])
        let v = JobView(job: job, steps: [done, failed])
        let step = HistoryModel.retryStep(v, models: models)?.0
        #expect(step?.idx == 1 && step?.task == "rig")  // a retry restarts at the failure
        var ok = job
        ok.state = .succeeded
        let all = JobView(job: ok, steps: [done, .init(jobId: "j", idx: 1, recipe: "unirig", task: "rig", inputs: [:], settings: [:], state: .succeeded, outputs: [])])
        #expect(HistoryModel.retryStep(all, models: models)?.0.idx == 0)  // succeeded: all steps again
        let gone = JobView(job: ok, steps: [done, .init(jobId: "j", idx: 1, recipe: "nope", task: "rig", inputs: [:], settings: [:], state: .failed, outputs: [])])
        #expect(HistoryModel.retryStep(gone, models: models) == nil)  // the recipe was uninstalled
    }

    @Test func anotherModelOffersTheSameKindOfTask() async throws {
        let lift = try await UIFixtures.lift(bundle: UIFixtures.devRecipes)
        _ = try await lift.settingsSet("dev_recipes", .bool(false))  // as users see it: no Test Cube
        let models = try await lift.modelsList()
        let at = Date()
        let job = JobRecord(id: "j", title: "t", priority: .normal, position: 1, source: .ui, state: .failed, forceStart: false,
                            currentStep: 0, createdAt: at, updatedAt: at)
        let v = JobView(job: job, steps: [StepRecord(jobId: "j", idx: 0, recipe: "hunyuan3d2", task: "image_to_3d",
                                                     inputs: [:], settings: [:], state: .failed, outputs: [])])
        let alts = HistoryModel.alternatives(v, models: models)
        #expect(alts.contains { $0.0.id == "pixal3d" && $0.1.id == "image_to_3d" })
        #expect(alts.contains { $0.0.id == "trellis2-mac" && $0.1.id == "image_to_3d" })
        #expect(!alts.contains { $0.0.id == "hunyuan3d2" })  // the model it already used
        #expect(alts.allSatisfy { $0.1.inputs.map(\.type) == [.image] && $0.1.output == .mesh })  // interchangeable: same kind
        let rig = JobView(job: job, steps: [StepRecord(jobId: "j", idx: 0, recipe: "unirig", task: "rig",
                                                        inputs: [:], settings: [:], state: .failed, outputs: [])])
        #expect(HistoryModel.alternatives(rig, models: models).isEmpty)  // nothing else rigs: the menu stays off
    }

    @Test func curlResubmitsTheSameJob() async throws {
        let lift = try await UIFixtures.lift()
        let v = try await lift.jobsSubmit(SubmitRequest(steps: [
            StepRequest(recipe: "test-cube", task: "image_to_3d", inputs: ["image": try UIFixtures.file("it's.png").path], settings: ["size": .float(2)]),
            StepRequest(recipe: "test-cube", task: "fake_rig"),
        ], priority: .high)).accepted()
        let curl = HistoryModel.curl(v, apiBase: "http://127.0.0.1:7777/v1", models: try await lift.modelsList())
        let prefix = "curl -X POST http://127.0.0.1:7777/v1/jobs -H 'Content-Type: application/json' -d '"
        #expect(curl.hasPrefix(prefix) && curl.hasSuffix("'"))
        let json = String(curl.dropFirst(prefix.count).dropLast()).replacingOccurrences(of: "'\\''", with: "'")
        let body = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let steps = try #require(body["steps"] as? [[String: Any]])
        #expect(body["priority"] as? String == "high" && steps.count == 2)
        #expect((steps[0]["inputs"] as? [String: String])?["image"] == v.steps[0].inputs["image"])
        #expect((steps[1]["inputs"] as? [String: String])?.isEmpty == true)  // filled from step 1 when it runs
        #expect((steps[0]["settings"] as? [String: Any])?["size"] as? Double == 2)
    }
}
