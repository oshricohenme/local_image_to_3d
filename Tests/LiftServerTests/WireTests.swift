import Foundation
import LiftCore
import Testing
@testable import LiftServer

@Suite struct InputsTests {
    func resolve(_ inputs: [String: String], files: [String: URL] = [:]) throws -> (SubmitRequest, Inputs) {
        let i = Inputs(workdir: try Fixtures.tempDir())
        let wire = SubmitWire(steps: [.init(recipe: "test-cube", task: "image_to_3d", inputs: inputs, settings: nil)])
        return (try i.resolve(wire, files: files, source: .http), i)
    }

    func errors(_ inputs: [String: String], files: [String: URL] = [:]) -> [String] {
        do { _ = try resolve(inputs, files: files) } catch let LiftError.invalidInput(e) { return e.map(\.field) } catch { return ["\(error)"] }
        return []
    }

    @Test func pathsPassThrough() throws {
        #expect(try resolve(["image_path": "/a.png"]).0.steps[0].inputs == ["image": "/a.png"])
        #expect(try resolve(["image": "/a.png"]).0.steps[0].inputs == ["image": "/a.png"])
    }

    @Test func base64IsSavedUnderItsFilename() throws {
        let (request, inputs) = try resolve(["mesh_base64": Data("glTF".utf8).base64EncodedString(), "mesh_filename": "../in.glb"])
        let path = try #require(request.steps[0].inputs["mesh"])
        #expect(path.hasPrefix(inputs.uploads.path) && path.hasSuffix("/0-mesh/in.glb"))
        #expect(try Data(contentsOf: URL(filePath: path)) == Data("glTF".utf8))
        inputs.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func aBase64InputNameCannotLeaveTheUploadsFolder() throws {
        let workdir = try Fixtures.tempDir()
        let key = "a/../../../escaped"
        let wire = SubmitWire(steps: [.init(recipe: "test-cube", task: "image_to_3d",
                                            inputs: ["\(key)_base64": Data("x".utf8).base64EncodedString(), "\(key)_filename": "evil.plist"], settings: nil)])
        let inputs = Inputs(workdir: workdir)
        do { _ = try inputs.resolve(wire, source: .http); Issue.record("accepted") } catch let LiftError.invalidInput(e) {
            #expect(e.map(\.field) == ["steps[0].inputs.\(key)_base64"])
        }
        // Nothing lands in the workdir outside uploads/.
        #expect(try FileManager.default.contentsOfDirectory(atPath: workdir.path).filter { $0 != "uploads" } == [])
    }

    @Test func badInputsAreFieldErrors() throws {
        #expect(errors(["image_base64": "%%%"]) == ["steps[0].inputs.image_base64"])
        #expect(errors(["image_filename": "a.png"]) == ["steps[0].inputs.image_filename"])
        #expect(errors(["image": "/a", "image_path": "/b"]) == ["steps[0].inputs.image_path"])
        #expect(errors([:], files: ["steps[3].image": URL(filePath: "/x")]) == ["steps[3].image"])
        #expect(errors([:], files: ["image": URL(filePath: "/x")]) == ["image"])
    }

    @Test func multipartPartsFillTheirStep() throws {
        #expect(try resolve([:], files: ["steps[0].image": URL(filePath: "/up/a.png")]).0.steps[0].inputs == ["image": "/up/a.png"])
    }

    @Test func outputNamesWithSpacesAndAccentsAreEscaped() {
        let out = OutputFile(job: "j1", path: "/w/jobs/j1/steps/0/my mesh é.glb")
        #expect(out.uri == "lift://jobs/j1/outputs/my%20mesh%20%C3%A9.glb" && out.url == "/v1/jobs/j1/outputs/my%20mesh%20%C3%A9.glb")
    }
}

@Suite struct ProblemTests {
    @Test func liftErrorsMapToStatusesAndCodes() {
        #expect(Problem.from(LiftError.notFound("job x")).status == 404)
        let input = Problem.from(LiftError.invalidInput([FieldError("steps[0].settings.size", "must be ≥ 0.01")]))
        #expect(input.status == 422 && input.error == "invalid_input" && input.fields?.first?.field == "steps[0].settings.size")
        let gate = Problem.from(ConfirmationRequired(impact: "Deletes job"))
        #expect(gate.status == 409 && gate.error == "confirmation_required" && gate.impact == "Deletes job")
        let failed = Problem.from(LiftError.commandFailed(command: "uv venv", exitCode: 2, tail: ["boom"]))
        #expect(failed.status == 500 && failed.command == "uv venv" && failed.tail == ["boom"])
    }

    @Test func wireJSONIsSnakeCaseButKeepsDictionaryKeys() throws {
        struct Sample: Encodable { var waitReason: String; var settings: [String: Int] }
        let json = String(decoding: try Wire.data(Sample(waitReason: "x", settings: ["lowVram": 1])), as: UTF8.self)
        #expect(json == #"{"settings":{"lowVram":1},"wait_reason":"x"}"#)
    }
}
