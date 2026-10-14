import Foundation
import HTTPTypes
import LiftCore
import Testing
@testable import LiftServer

extension Fixtures {
    /// A Lift with developer recipes shown and nothing installed: no Homebrew, an in-memory secret store,
    /// a temp Hugging Face cache and weights metadata that is always offline, so nothing reaches the Hub.
    static func lift(installCube: Bool = false) async throws -> Lift {
        let lift = try await Lift.open(LiftConfig(workdir: try tempDir(), workerRuntime: workerRuntime, bundledRecipes: devRecipes,
                                                  homebrewPrefix: "/nonexistent-homebrew", rosettaPrefix: "/nonexistent-rosetta",
                                                  housekeepingInterval: .milliseconds(200), heartbeatSeconds: 0.2,
                                                  hfHub: try tempDir(), weightsMetadata: OfflineHub()))
        _ = try await lift.settingsSet("dev_recipes", .bool(true))
        if installCube {
            let model = try await lift.modelsInstall("test-cube", confirm: true, wait: true).value
            guard case .installed = model?.status else {
                throw LiftError.invalidState("test-cube install failed: \(String(describing: model?.status))\n\((try? await lift.modelsInstallLog("test-cube")) ?? "")")
            }
        }
        return lift
    }

    /// Requests carrying this header count as coming from another machine.
    static let remoteHeader = HTTPField.Name("X-Test-Remote")!

    static func server(_ lift: Lift, port: Int = 0) -> LiftServer {
        LiftServer(lift: lift, configuration: .init(port: port, isRemote: { $0[remoteHeader] != nil }, rebindDelay: .milliseconds(50), lanHost: "127.0.0.1"))
    }
}

struct OfflineHub: WeightsMetadata {
    func snapshot(repo: String, revision: String) async throws -> RepoSnapshot { throw WeightsMetadataError.offline }
}

/// One Lift with Test Cube installed for real and one server on a free port, shared by the HTTP and MCP suites.
actor ServerFixture {
    static let shared = ServerFixture()
    private var value: (lift: Lift, server: LiftServer, base: URL)?

    func get() async throws -> (lift: Lift, server: LiftServer, base: URL) {
        if let value { return value }
        let lift = try await Fixtures.lift(installCube: true)
        let server = Fixtures.server(lift)
        let status = try await server.start()
        let v = (lift, server, URL(string: "http://127.0.0.1:\(status.port)")!)
        value = v
        return v
    }
}

/// A small HTTP client for the tests (URLSession).
struct HTTP {
    let base: URL
    var headers: [String: String] = [:]

    struct Reply {
        var status: Int
        var data: Data
        var response: HTTPURLResponse
        var json: [String: Any] { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:] }
        var text: String { String(decoding: data, as: UTF8.self) }
    }

    func call(_ method: String, _ path: String, json: Any? = nil, body: Data? = nil, contentType: String? = nil) async throws -> Reply {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = method
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        if let json {
            request.httpBody = try JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        return Reply(status: http.statusCode, data: data, response: http)
    }
}
