import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// M1: variables in Lift's own environment that would redirect a child's Python or shim never reach tool
/// commands or workers; only what Lift sets explicitly does.
@Suite(.serialized) struct EnvHygieneTests {
    static let polluted = ["LIFT_SHIM": #"{"bogus":1}"#, "PYTHONPATH": "/nonexistent-lift-test", "PYTHONHOME": "/nonexistent-lift-test",
                           "VIRTUAL_ENV": "/nonexistent-lift-test"]

    func polluted<T>(_ body: () async throws -> T) async rethrows -> T {
        for (k, v) in Self.polluted { setenv(k, v, 1) }
        defer { for k in Self.polluted.keys { unsetenv(k) } }
        return try await body()
    }

    @Test func toolCommandsGetNoInheritedPythonOrShimVariables() async throws {
        let out = try await polluted { try await SubprocessRunner().output(ShellCommand("/usr/bin/env")) }
        for k in Self.polluted.keys { #expect(!out.contains("\(k)=")) }
        let explicit = try await polluted { try await SubprocessRunner().output(ShellCommand("/usr/bin/env", environment: ["VIRTUAL_ENV": "/venv"])) }
        #expect(explicit.contains("VIRTUAL_ENV=/venv"))
    }

    @Test func workersGetOnlyWhatLiftSets() async throws {
        let lines = try await polluted { () async throws -> [String] in
            let w = WorkerProcess(executable: "/usr/bin/env", arguments: [], environment: ["PYTHONPATH": "/explicit"], workingDirectory: nil)
            let r = EventRecorder(w)
            return try await r.wait(for: isExited).compactMap { if case .malformed(let l) = $0 { l } else { nil } }
        }
        #expect(lines.contains("PYTHONPATH=/explicit"))
        for k in ["LIFT_SHIM", "PYTHONHOME", "VIRTUAL_ENV"] { #expect(!lines.contains { $0.hasPrefix("\(k)=") }) }
    }

    @Test func hfDownloadGetsNoShimOrPythonPath() async throws {
        let runner = FakeRunner()
        let models = try Fixtures.tempDir()
        let inst = Installer(runner: runner, models: models, workerRuntime: URL(filePath: "/lift/runtime"), tools: ToolPaths(git: "/bin/git", uv: "/bin/uv"),
                             toolEnvironment: ["PATH": "/bin"], hfToken: { "hf_x" }, hfHub: URL(filePath: "/hf/hub"))
        guard case .ok(let recipe) = RecipeLoad.read(directory: try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())) else { return }
        let bin = inst.dir("pixal3d").appending(path: "venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin.appending(path: "hf"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "hf").path)
        try #"{"aliases":{},"env":{},"patches":[],"standins":[]}"#.write(to: inst.shimURL("pixal3d"), atomically: true, encoding: .utf8)
        try await inst.downloadWeights(recipe, onLine: { _ in })
        for c in runner.commands {
            #expect(c.environment["LIFT_SHIM"] == nil && c.environment["PYTHONPATH"] == nil)
            #expect(c.environment["HF_HUB_CACHE"] == "/hf/hub" && c.environment["HF_TOKEN"] == "hf_x")
        }
    }
}
