import Foundation
import Testing
@testable import LiftCore

/// Slow and opt-in: a real install of bundled recipes into a temp workdir: clone at the pins, build the venv and
/// the Metal substitutes, and pass the smoke check (which imports upstream under lift_shim). No weights are
/// downloaded. LIFT_REAL_INSTALL is a comma-separated list of recipe ids, e.g. `pixal3d,trellis2-mac`.
@Suite(.serialized, .timeLimit(.minutes(60))) struct RealInstallTests {
    static let ids = (ProcessInfo.processInfo.environment["LIFT_REAL_INSTALL"] ?? "").split(separator: ",").map(String.init)

    @Test(.enabled(if: !ids.isEmpty), arguments: ids)
    func installsAndPassesTheSmokeCheck(id: String) async throws {
        let lift = try await Lift.open(LiftConfig(workdir: try Fixtures.tempDir(), workerRuntime: Fixtures.workerRuntime,
                                                  bundledRecipes: Fixtures.devRecipes, hfToken: { "hf_not_used_without_weights" },
                                                  hfHub: try Fixtures.tempDir(), weightsMetadata: FakeMetadata()))
        let model = try await lift.modelsInstall(id, confirm: true, wait: true, downloadWeights: false).value
        let log = (try? await lift.modelsInstallLog(id)) ?? ""
        #expect(model?.status == .installed(commit: model?.recipe.commit), "\(log.suffix(4000))")
        #expect(log.contains("lift_worker: launcher OK"))
        #expect(FileManager.default.isExecutableFile(atPath: lift.config.workdir.appending(path: "models/\(id)/venv/bin/hf").path))  // for weight downloads
    }
}
