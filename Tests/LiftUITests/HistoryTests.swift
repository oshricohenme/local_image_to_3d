import Foundation
import LiftCore
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
