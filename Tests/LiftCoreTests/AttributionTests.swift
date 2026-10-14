import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// An attribution block as JSON (the same shape recipe.yaml uses).
func attribution(_ json: String) throws -> Attribution {
    try JSONDecoder().decode(Attribution.self, from: Data(json.utf8))
}

let cubeAttributionJSON = #"""
{"project": "Test Cube", "authors": ["Lift"], "homepage": "https://example.org/cube",
 "license": {"spdx": "MIT", "url": "https://example.org/cube/LICENSE"},
 "components": [{"name": "RMBG-2.0", "role": "background removal", "url": "https://huggingface.co/briaai/RMBG-2.0",
                 "license": {"spdx": "CC-BY-NC-4.0", "url": "https://creativecommons.org/licenses/by-nc/4.0/"},
                 "restrictions": ["non-commercial"]}]}
"""#

@Suite struct AttributionTests {
    @Test func creditAndTheFixedDisclaimer() throws {
        let a = try attribution(cubeAttributionJSON)
        #expect(a.credit == "Test Cube by Lift (MIT)")
        #expect(a.disclaimer == "Test Cube was created by Lift. Lift is an independent app that runs open-source projects on your Mac. "
                + "Lift did not create Test Cube and is not affiliated with or endorsed by its authors.")
        #expect(a.components.first?.restrictions == ["non-commercial"] && a.problems.isEmpty)
    }

    @Test func restrictionsDefaultToNone() throws {
        let a = try attribution(#"""
        {"project": "P", "authors": ["A"], "homepage": "https://p.org", "license": {"spdx": "MIT", "url": "https://p.org/L"},
         "components": [{"name": "W", "role": "model weights", "url": "https://hf.co/w", "license": {"spdx": "MIT", "url": "https://hf.co/w"}}]}
        """#)
        #expect(a.components[0].restrictions.isEmpty && a.repo == nil && a.paper == nil)
    }

    @Test func incompleteBlocksAreNamed() throws {
        let a = try attribution(#"""
        {"project": " ", "authors": [], "homepage": "http://p.org", "license": {"spdx": "", "url": "https://p.org/L"},
         "components": [{"name": "W", "role": "", "url": "https://hf.co/w", "license": {"spdx": "MIT", "url": "https://hf.co/w"}}]}
        """#)
        #expect(a.problems == ["attribution.project is required", "attribution.authors must list who made it", "attribution.license.spdx is required",
                               "attribution: http://p.org must be an https URL", "attribution.components[0] needs a name, a role and a license"])
        #expect(throws: DecodingError.self) { try attribution(#"{"project": "P"}"#) }  // missing fields don't decode at all
    }

    @Test func encodesCreditAndDisclaimerForClients() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try attribution(cubeAttributionJSON))) as! [String: Any]
        #expect(object["credit"] as? String == "Test Cube by Lift (MIT)")
        #expect((object["disclaimer"] as? String)?.hasPrefix("Test Cube was created by Lift.") == true)
        #expect(try JSONDecoder().decode(Attribution.self, from: JSONEncoder().encode(try attribution(cubeAttributionJSON))) == (try attribution(cubeAttributionJSON)))
    }
}

/// Answers GETs from a table and records them; a missing URL is a non-200 (nil), `offline` throws.
final class FakeReadmeHTTP: ReadmeHTTP {
    private let state = Mutex<(answers: [String: String], offline: Bool, asked: [String])>(([:], false, []))
    func set(_ url: String, _ text: String) { state.withLock { $0.answers[url] = text } }
    func goOffline() { state.withLock { $0.offline = true } }
    var asked: [String] { state.withLock { $0.asked } }

    func get(_ url: URL) async throws -> Data? {
        let (answer, offline) = state.withLock { s in
            s.asked.append(url.absoluteString)
            return (s.answers[url.absoluteString], s.offline)
        }
        if offline { throw URLError(.notConnectedToInternet) }
        return answer.map { Data($0.utf8) }
    }
}

@Suite struct ReadmeTests {
    let raw = "https://raw.githubusercontent.com/TencentARC/Pixal3D/f7cf38429b0bd264f1995f0f8743a88b1c728b94/"

    func recipe(_ yaml: String = pixalYAML) throws -> Recipe {
        guard case .ok(let r) = RecipeLoad.read(directory: try writeRecipe(yaml, id: "pixal3d", in: try Fixtures.tempDir())) else {
            throw LiftError.invalidState("fixture")
        }
        return r
    }

    @Test func fetchesAtThePinCachesAndFallsBackOffline() async throws {
        let http = FakeReadmeHTTP()
        http.set(raw + "README.md", "# Pixal3D\n![teaser](assets/teaser.png)")
        let model = try Fixtures.tempDir()
        let loader = ReadmeLoader(http: http)
        let live = try #require(await loader.load(try recipe(), modelDir: model, installed: false))
        #expect(live == Readme(text: "# Pixal3D\n![teaser](assets/teaser.png)", baseURL: URL(string: raw)!, cached: false))
        #expect(try String(contentsOf: model.appending(path: "readme/README.md"), encoding: .utf8) == live.text)
        http.goOffline()
        #expect(await loader.load(try recipe(), modelDir: model, installed: false) == Readme(text: live.text, baseURL: URL(string: raw)!, cached: true))
        #expect(await loader.load(try recipe(), modelDir: try Fixtures.tempDir(), installed: false) == nil)  // offline, never cached
    }

    @Test func anInstalledModelReadsItsOwnClone() async throws {
        let http = FakeReadmeHTTP()
        let model = try Fixtures.tempDir()
        try FileManager.default.createDirectory(at: model.appending(path: "repo"), withIntermediateDirectories: true)
        try "local readme".write(to: model.appending(path: "repo/Readme.markdown"), atomically: true, encoding: .utf8)
        let r = try #require(await ReadmeLoader(http: http).load(try recipe(), modelDir: model, installed: true))
        #expect(r.text == "local readme" && !r.cached && http.asked.isEmpty)
    }

    @Test func aPinOverrideAndNonGitHubRepos() async throws {
        let http = FakeReadmeHTTP()
        let pin = String(repeating: "a", count: 40)
        http.set("https://raw.githubusercontent.com/TencentARC/Pixal3D/\(pin)/README.md", "pinned")
        #expect(await ReadmeLoader(http: http).load(try recipe(), pin: pin, modelDir: try Fixtures.tempDir(), installed: false)?.text == "pinned")
        #expect(ReadmeLoader.githubSlug("https://github.com/shivampkumar/trellis-mac.git") == "shivampkumar/trellis-mac")
        #expect(ReadmeLoader.githubSlug("https://gitlab.com/a/b") == nil)
    }
}
