import Foundation
import LiftCore
import Testing
@testable import LiftServer

/// The real server on a free port, with Test Cube installed and real workers (spec §14 integration).
@Suite(.serialized, .timeLimit(.minutes(10))) struct HTTPTests {
    func cube(_ inputs: [String: String], settings: [String: Any] = [:]) -> [String: Any] {
        ["recipe": "test-cube", "task": "image_to_3d", "inputs": inputs, "settings": settings]
    }

    func wait(_ http: HTTP, _ id: String) async throws -> [String: Any] {
        try await http.call("GET", "/v1/jobs/\(id)/wait?timeout_seconds=120").json
    }

    @Test func submitWaitAndDownloadTheOutput() async throws {
        let (_, _, base) = try await ServerFixture.shared.get()
        let http = HTTP(base: base)
        let submit = try await http.call("POST", "/v1/jobs", json: ["steps": [cube(["image_path": try Fixtures.image()], settings: ["size": 2])], "title": "cube"])
        #expect(submit.status == 202)
        let id = try #require((submit.json["job"] as? [String: Any])?["id"] as? String)
        #expect(submit.response.value(forHTTPHeaderField: "Location") == "/v1/jobs/\(id)")
        let done = try await wait(http, id)
        #expect((done["job"] as? [String: Any])?["state"] as? String == "succeeded")
        let output = try #require((done["outputs"] as? [[String: Any]])?.first)
        #expect(output["uri"] as? String == "lift://jobs/\(id)/outputs/cube.glb")
        #expect((output["path"] as? String)?.hasSuffix("/steps/0/cube.glb") == true)
        let file = try await http.call("GET", try #require(output["url"] as? String))
        #expect(file.status == 200 && file.data.prefix(4) == Data("glTF".utf8))
    }

    @Test func waitWithZeroTimeoutAnswersAtOnce() async throws {
        let (_, _, base) = try await ServerFixture.shared.get()
        let http = HTTP(base: base)
        let id = try #require((try await http.call("POST", "/v1/jobs", json: ["steps": [cube(["image_path": try Fixtures.image()], settings: ["delay": 2])]])
            .json["job"] as? [String: Any])?["id"] as? String)
        let now = try await http.call("GET", "/v1/jobs/\(id)/wait?timeout_seconds=0").json
        #expect(["queued", "waiting", "loading", "running"].contains((now["job"] as? [String: Any])?["state"] as? String ?? ""))
        #expect((try await wait(http, id)["job"] as? [String: Any])?["state"] as? String == "succeeded")
    }

    @Test func multipartAndBase64Uploads() async throws {
        let (lift, _, base) = try await ServerFixture.shared.get()
        let http = HTTP(base: base)
        let boundary = "lift-test-boundary"
        var body = Data()
        func part(_ headers: String, _ content: Data) {
            body.append(Data("--\(boundary)\r\n\(headers)\r\n\r\n".utf8))
            body.append(content)
            body.append(Data("\r\n".utf8))
        }
        part("Content-Disposition: form-data; name=\"job\"\r\nContent-Type: application/json",
             try JSONSerialization.data(withJSONObject: ["steps": [["recipe": "test-cube", "task": "image_to_3d"]]]))
        part("Content-Disposition: form-data; name=\"steps[0].image\"; filename=\"upload.png\"\r\nContent-Type: image/png", Data([0x89, 0x50, 0x4E, 0x47]))
        body.append(Data("--\(boundary)--\r\n".utf8))
        let multipart = try await http.call("POST", "/v1/jobs", body: body, contentType: "multipart/form-data; boundary=\(boundary)")
        #expect(multipart.status == 202)

        let base64 = try await http.call("POST", "/v1/jobs", json: ["steps": [cube(["image_base64": Data([0x89, 0x50]).base64EncodedString(), "image_filename": "inline.png"])]])
        #expect(base64.status == 202)

        for (reply, name) in [(multipart, "upload.png"), (base64, "inline.png")] {
            let job = reply.json["job"] as? [String: Any]
            let image = ((reply.json["steps"] as? [[String: Any]])?.first?["inputs"] as? [String: String])?["image"]
            #expect(image?.hasPrefix(lift.config.workdir.appending(path: "jobs").path) == true && image?.hasSuffix("/\(name)") == true)
            #expect((try await wait(http, try #require(job?["id"] as? String))["job"] as? [String: Any])?["state"] as? String == "succeeded")
        }
        let uploads = (try? FileManager.default.contentsOfDirectory(atPath: lift.config.workdir.appending(path: "uploads").path)) ?? []
        #expect(uploads.isEmpty)
    }

    @Test func badInputIs422WithOneErrorPerField() async throws {
        let (lift, _, base) = try await ServerFixture.shared.get()
        let http = HTTP(base: base)
        let before = try await lift.jobsList().count
        let bad = try await http.call("POST", "/v1/jobs", json: ["steps": [cube(["image_path": try Fixtures.image()], settings: ["size": 0]),
                                                                          ["recipe": "nope", "task": "x"]]])
        #expect(bad.status == 422 && bad.json["error"] as? String == "invalid_input")
        #expect((bad.json["fields"] as? [[String: Any]])?.compactMap { $0["field"] as? String } == ["steps[0].settings.size", "steps[1].recipe"])
        let schema = try await http.call("POST", "/v1/jobs", json: ["steps": [cube(["image_path": "/x.png"])], "priority": "urgent"])
        #expect(schema.status == 422 && (schema.json["fields"] as? [[String: Any]])?.first?["field"] as? String == "priority")
        #expect(try await lift.jobsList().count == before)
    }

    @Test func confirmGatesAnswer409AndChangeNothing() async throws {
        let (_, _, base) = try await ServerFixture.shared.get()
        let http = HTTP(base: base)
        let id = try #require((try await http.call("POST", "/v1/jobs", json: ["steps": [cube(["image_path": try Fixtures.image()])], "title": "keep me"])
            .json["job"] as? [String: Any])?["id"] as? String)
        _ = try await wait(http, id)
        let gate = try await http.call("DELETE", "/v1/jobs/\(id)")
        #expect(gate.status == 409 && gate.json["error"] as? String == "confirmation_required")
        #expect((gate.json["impact"] as? String)?.contains("keep me") == true)
        #expect(try await http.call("GET", "/v1/jobs/\(id)").status == 200)
        let deleted = try await http.call("DELETE", "/v1/jobs/\(id)?confirm=true")
        #expect(deleted.status == 200 && deleted.json["deleted"] as? Bool == true)
        let gone = try await http.call("GET", "/v1/jobs/\(id)")
        #expect(gone.status == 404 && gone.json["error"] as? String == "not_found")
    }

    @Test func docsAndOpenAPIAreServed() async throws {
        let (_, _, base) = try await ServerFixture.shared.get()
        let http = HTTP(base: base)
        let spec = try await http.call("GET", "/openapi.json")
        #expect(spec.json["openapi"] as? String == "3.1.0")
        #expect((spec.json["paths"] as? [String: Any])?["/v1/jobs"] != nil)
        #expect(try await http.call("GET", "/docs").text.contains(#"<redoc spec-url="/openapi.json">"#))
        let js = try await http.call("GET", "/docs/redoc.standalone.js")
        #expect(js.status == 200 && js.data.count > 1_000_000)
    }

    @Test func everyReadRouteAnswersInItsSchema() async throws {
        let (_, server, base) = try await ServerFixture.shared.get()
        let http = HTTP(base: base)
        for path in ["/v1/jobs", "/v1/jobs?state=succeeded&state=failed", "/v1/jobs/interrupted", "/v1/queue", "/v1/models", "/v1/models/test-cube",
                     "/v1/recipes", "/v1/workers", "/v1/resources", "/v1/settings", "/v1/server", "/v1/system/prereqs"] {
            let r = try await http.call("GET", path)
            #expect(r.status == 200, "\(path): \(r.text)")
        }
        #expect(try await http.call("GET", "/v1/models/test-cube/install-log").text.contains("installed test-cube"))
        let status = try await http.call("GET", "/v1/server").json
        #expect(status["port"] as? Int == base.port && status["bind"] as? String == "127.0.0.1")
        let entry = (status["mcp_config"] as? [String: Any]).flatMap { ($0["mcpServers"] as? [String: Any])?["lift"] as? [String: Any] }
        #expect(entry?["args"] as? [String] == ["--url", "http://127.0.0.1:\(await server.port)/mcp"])
    }

    @Test func settingsRoundTrip() async throws {
        let (_, _, base) = try await ServerFixture.shared.get()
        let http = HTTP(base: base)
        let set = try await http.call("POST", "/v1/settings", json: ["key": "idle_unload_minutes", "value": 5])
        #expect(set.status == 200 && set.json["idle_unload_minutes"] as? Double == 5)
        #expect(try await http.call("GET", "/v1/settings").json["idle_unload_minutes"] as? Double == 5)
        let wrong = try await http.call("POST", "/v1/settings", json: ["key": "max_slots", "value": "many"])
        #expect(wrong.status == 422)
        _ = try await http.call("POST", "/v1/settings", json: ["key": "idle_unload_minutes", "value": 10])
        let resources = try await http.call("PATCH", "/v1/resources", json: ["max_slots": 1])
        #expect(resources.status == 200 && resources.json["max_slots"] as? Int == 1)
    }
}

/// Servers of their own (not the shared one): binding, LAN mode and the token change the server.
@Suite(.serialized) struct ServerControlTests {
    @Test func aTakenPortMovesToTheNextFreeOne() async throws {
        let lift = try await Fixtures.lift()
        let first = Fixtures.server(lift)
        let taken = try await first.start().port
        let second = Fixtures.server(lift, port: taken)
        let status = try await second.start()
        #expect(status.port > taken && status.port < taken + 20 && status.configuredPort == taken)
        await second.stop()
        await first.stop()
    }

    @Test func tooBigJobsWarnAndQueueNothingUntilAccepted() async throws {
        let lift = try await Fixtures.lift()
        let server = Fixtures.server(lift)
        let http = HTTP(base: URL(string: "http://127.0.0.1:\(try await server.start().port)")!)
        _ = try await http.call("PATCH", "/v1/resources", json: ["memory_budget_gb": 0.1])  // Test Cube estimates 0.5 GB
        let job: [String: Any] = ["steps": [["recipe": "test-cube", "task": "image_to_3d", "inputs": ["image_path": try Fixtures.image()]]]]
        let warned = try await http.call("POST", "/v1/jobs", json: job)
        #expect(warned.status == 200)
        let warning = try #require(warned.json["memory_warning"] as? [String: Any])
        #expect((warning["needed_gb"] as? Double ?? 0) > 0.1 && warning["message"] as? String != nil)
        #expect((warned.json["hint"] as? String)?.contains("accept_memory_warning") == true)
        #expect(try await lift.jobsList().isEmpty)
        var accepted = job
        accepted["accept_memory_warning"] = true
        #expect(try await http.call("POST", "/v1/jobs", json: accepted).status == 202)
        #expect(try await lift.jobsList().count == 1)
        await server.stop()
    }

    @Test func portAndHFTokenAreServerSettings() async throws {
        let lift = try await Fixtures.lift()
        let secrets = MemorySecretStore()
        let server = LiftServer(lift: lift, configuration: .init(secrets: secrets, port: 0))
        let http = HTTP(base: URL(string: "http://127.0.0.1:\(try await server.start().port)")!)
        let settings = try await http.call("GET", "/v1/settings").json
        #expect(settings["port"] as? Int == 7777 && settings["lan_mode"] as? Bool == false && settings["max_slots"] as? Int == 1)
        #expect(try await http.call("POST", "/v1/settings", json: ["key": "port", "value": 8123]).json["port"] as? Int == 8123)
        #expect(ServerSettings.load(lift.config.workdir).port == 8123)
        #expect(try await http.call("POST", "/v1/settings", json: ["key": "port", "value": 70000]).status == 422)
        #expect(try await http.call("POST", "/v1/settings", json: ["key": "lan_mode", "value": true]).status == 422)  // only server_set_lan

        let set = try await http.call("PUT", "/v1/secrets/hf-token", json: ["token": "hf_abc"])
        #expect(set.json["hf_token_set"] as? Bool == true && secrets.get(.hfToken) == "hf_abc" && secrets.hfTokenReader() == "hf_abc")
        #expect(try await http.call("PUT", "/v1/secrets/hf-token", json: [:]).json["hf_token_set"] as? Bool == false)
        await server.stop()
    }

    @Test func lanModeNeedsTheBearerTokenFromOtherMachines() async throws {
        let lift = try await Fixtures.lift()
        let server = Fixtures.server(lift)
        let base = URL(string: "http://127.0.0.1:\(try await server.start().port)")!
        let local = HTTP(base: base)
        var remote = HTTP(base: base, headers: ["X-Test-Remote": "1"])
        #expect(try await remote.call("GET", "/v1/queue").status == 403)

        #expect(try await local.call("POST", "/v1/server/lan", json: ["enabled": true]).status == 409)
        let on = try await local.call("POST", "/v1/server/lan?confirm=true", json: ["enabled": true])
        let token = try #require(on.json["token"] as? String)
        #expect((on.json["server"] as? [String: Any])?["lan_mode"] as? Bool == true)
        #expect(try await eventually { await server.status().lanMode })
        #expect(await server.status().port == base.port)

        let refused = try await remote.call("GET", "/v1/queue")
        #expect(refused.status == 401 && refused.response.value(forHTTPHeaderField: "WWW-Authenticate") == "Bearer")
        remote.headers["Authorization"] = "Bearer \(token)"
        #expect(try await remote.call("GET", "/v1/queue").status == 200)
        #expect(try await local.call("GET", "/v1/queue").status == 200)

        let rotated = try #require(try await remote.call("POST", "/v1/server/token/rotate?confirm=true").json["token"] as? String)
        #expect(rotated != token)
        #expect(try await remote.call("GET", "/v1/queue").status == 401)
        remote.headers["Authorization"] = "Bearer \(rotated)"
        #expect(try await remote.call("GET", "/v1/queue").status == 200)
        await server.stop()
    }
}
