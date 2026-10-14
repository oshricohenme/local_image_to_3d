import Foundation
import Testing
@testable import LiftCore

/// What recipes show people (principle 4, spec §4a): plain failure messages and the upstream README.
extension CubeIntegrationTests {
    @Test func aKnownFailureShowsTheRecipesPlainMessageThenTheDetails() async throws {
        let lift = try await CubeFixture.shared.get()
        let failed = try await run(lift, [try cube(["fail": .bool(true)])])
        let error = try #require(failed.job.error)
        #expect(error.hasPrefix("The Test Cube failed because its Fail setting is on.\n\nDetails: "))
        #expect(error.contains("failed on purpose"))
    }
}

@Suite struct ModelsReadmeTests {
    @Test func readmeAtThePinThroughLift() async throws {
        let http = FakeReadmeHTTP()
        let raw = "https://raw.githubusercontent.com/TencentARC/Pixal3D/f7cf38429b0bd264f1995f0f8743a88b1c728b94/"
        http.set(raw + "README.md", "# Pixal3D")
        let lift = try await Fixtures.lift(readme: http)
        #expect(try await lift.modelsReadme("pixal3d") == Readme(text: "# Pixal3D", baseURL: URL(string: raw)!, cached: false))
        #expect(FileManager.default.fileExists(atPath: lift.config.workdir.appending(path: "models/pixal3d/readme/README.md").path))
        #expect(try await lift.modelsReadme("test-cube") == nil)  // no upstream repo
        await #expect(throws: LiftError.self) { _ = try await lift.modelsReadme("nope") }
    }
}
