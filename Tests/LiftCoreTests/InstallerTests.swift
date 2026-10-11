import Foundation
import Testing
@testable import LiftCore

@Suite struct InstallerTests {
    /// A source with pixal3d (repo, shim, flash_attn substitute) and the shared registry.
    func source(_ yaml: String = pixalYAML) throws -> CatalogEntry {
        let root = try Fixtures.tempDir()
        let folder = try writeRecipe(yaml, id: "pixal3d", in: root)
        let shared = root.appending(path: "shared")
        try FileManager.default.createDirectory(at: shared.appending(path: "lift_shim"), withIntermediateDirectories: true)
        try "flash_attn: { standin: flash_attn }\n".write(to: shared.appending(path: "substitutes.yaml"), atomically: true, encoding: .utf8)
        guard case .ok(let recipe) = RecipeLoad.read(directory: folder) else { throw LiftError.invalidState("fixture") }
        return CatalogEntry(recipe: recipe, source: "test", directory: folder, shared: shared)
    }

    func installer(_ runner: FakeRunner, token: String? = "hf_x", brew: String? = "/brew/bin/brew") throws -> Installer {
        Installer(runner: runner, models: try Fixtures.tempDir(), workerRuntime: URL(filePath: "/lift/runtime"),
                  tools: ToolPaths(brew: brew, git: "/bin/git", uv: "/bin/uv"), toolEnvironment: ["PATH": "/bin"],
                  hfToken: { token }, hfHub: URL(filePath: "/hf/hub"))
    }

    @Test func runsEveryStepInOrderAndMarksInstalled() async throws {
        let runner = FakeRunner()
        let entry = try source()
        let inst = try installer(runner)
        let m = inst.dir("pixal3d").path
        try FileManager.default.createDirectory(at: entry.directory.appending(path: "files"), withIntermediateDirectories: true)
        try "x = 1\n".write(to: entry.directory.appending(path: "files/helper.py"), atomically: true, encoding: .utf8)
        try await inst.install(entry, pin: nil, onLine: { _ in })
        #expect(FileManager.default.fileExists(atPath: inst.installedRecipeDir("pixal3d").appending(path: "files/helper.py").path))
        #expect(runner.displays == [
            "/brew/bin/brew install libusb",
            "/bin/git clone --filter=blob:none https://github.com/TencentARC/Pixal3D \(m)/.repo-staging",
            "/bin/git -C \(m)/.repo-staging checkout --quiet f7cf38429b0bd264f1995f0f8743a88b1c728b94",
            "/bin/git -C \(m)/.repo-staging submodule update --init --recursive --quiet",
            "/bin/uv venv --python 3.11 \(m)/venv",
            "uv pip install torch torchvision",
            "/bin/uv pip install \(entry.shared.path)/lift_shim",
            "\(m)/venv/bin/python -c import site, lift_shim.pth as p; p.write_pth(site.getsitepackages()[0])",
            "\(m)/venv/bin/python -m lift_worker --check \(inst.workerConfig(entry.recipe, heartbeat: 2))",
        ])
        let step = runner.commands[5]
        #expect(step.environment["VIRTUAL_ENV"] == "\(m)/venv" && step.environment["PATH"] == "\(m)/venv/bin:/bin" && step.workingDirectory == m)
        let smoke = runner.commands[8].environment
        #expect(smoke["LIFT_SHIM"] == #"{"aliases":{},"env":{"ATTN_BACKEND":"sdpa"},"patches":["transformers_fa2_to_sdpa"],"standins":["flash_attn"]}"#)
        #expect(smoke["PYTHONPATH"] == "/lift/runtime" && smoke["HF_HUB_CACHE"] == "/hf/hub" && smoke["HF_TOKEN"] == "hf_x")
        #expect(smoke["DYLD_FALLBACK_LIBRARY_PATH"] == "/brew/lib:/usr/lib")  // native brew only, never /usr/local
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .installed(commit: entry.recipe.commit))
        #expect(inst.installedRecipe("pixal3d") == entry.recipe)
        let log = try String(contentsOf: inst.logURL("pixal3d"), encoding: .utf8)
        #expect(log.contains("$ uv pip install torch torchvision") && log.contains("installed pixal3d"))
    }

    @Test func failureKeepsTheLogAndNeverCountsAsInstalled() async throws {
        let runner = FakeRunner()
        runner.on("uv pip install torch", code: 1, lines: ["error: no matching distribution"])
        let entry = try source()
        let inst = try installer(runner)
        await #expect(throws: LiftError.commandFailed(command: "uv pip install torch torchvision", exitCode: 1, tail: ["error: no matching distribution"])) {
            try await inst.install(entry, pin: nil, onLine: { _ in })
        }
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .installFailed(command: "uv pip install torch torchvision", exitCode: 1,
                                                                                   reason: "Setting up Python failed: no matching distribution"))
        #expect(inst.installedRecipe("pixal3d") == nil)
        #expect(try String(contentsOf: inst.logURL("pixal3d"), encoding: .utf8).contains("error: no matching distribution"))
        #expect(!runner.displays.contains { $0.contains("lift_worker --check") })
    }

    /// UniRig's real clone failure (first real run): the reason names the step and the error, not the progress lines.
    @Test func aFailedStepIsExplainedInPlainWords() {
        let output = """
        `/usr/bin/git clone --filter=blob:none https://github.com/VAST-AI-Research/UniRig /x/.repo-staging` failed with exit code 128
        Cloning into '/x/.repo-staging'...
        Updating files:  24% (34/141)
        git-lfs filter-process: git-lfs: command not found
        fatal: the remote end hung up unexpectedly
        warning: Clone succeeded, but checkout failed.
        """
        #expect(InstallFailure.explain(command: "/usr/bin/git clone --filter=blob:none https://github.com/VAST-AI-Research/UniRig /x", output: output)
                == "Getting the code from GitHub failed: a program it needs, git-lfs, isn't installed.")
        #expect(InstallFailure.explain(command: "/usr/bin/git clone x", output: "fatal: unable to access 'https://github.com/a/b/': Could not resolve host: github.com")
                == "Getting the code from GitHub failed: Lift couldn't reach the internet. Check your connection and try again.")
        #expect(InstallFailure.explain(command: "/opt/homebrew/bin/brew install cmake", output: "Error: No space left on device")
                == "Installing tools with Homebrew failed: your Mac is out of disk space. Free up some space and try again.")
        #expect(InstallFailure.explain(command: nil, output: "the recipe folder is gone") == "The install failed: the recipe folder is gone")
    }

    @Test func brewPackagesNeedNativeHomebrew() async throws {
        let runner = FakeRunner()
        await #expect(throws: LiftError.self) { try await self.installer(runner, brew: nil).install(try self.source(), pin: nil, onLine: { _ in }) }
        #expect(runner.commands.isEmpty)
    }

    /// M10: any failure (not only a failing command) marks the install failed, with the reason, in state and log.
    @Test func anyInstallFailureIsRecorded() async throws {
        let runner = FakeRunner()
        let entry = try source()
        runner.on("uv pip install torch", effect: { try? FileManager.default.removeItem(at: entry.directory) })  // the recipe folder vanishes
        let inst = try installer(runner)
        await #expect(throws: (any Error).self) { try await inst.install(entry, pin: nil, onLine: { _ in }) }
        guard case .installFailed(_, let code, let reason) = inst.status(id: "pixal3d", source: nil, pin: nil) else {
            Issue.record("status \(inst.status(id: "pixal3d", source: nil, pin: nil))"); return
        }
        #expect(code == -1 && !reason.isEmpty)
        #expect(try String(contentsOf: inst.logURL("pixal3d"), encoding: .utf8).contains("install failed: "))
    }

    @Test func gatedWeightsNeedAToken() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner, token: nil)
        await #expect(throws: LiftError.self) { try await inst.install(try source(), pin: nil, onLine: { _ in }) }
        #expect(runner.commands.isEmpty)
    }

    @Test func notEnoughDiskIsRefused() async throws {
        let runner = FakeRunner()
        let yaml = pixalYAML.replacingOccurrences(of: "memory_keys: [low_vram, resolution]", with: "memory_keys: [low_vram, resolution]\n  disk_gb: 99999")
        await #expect(throws: LiftError.self) { try await self.installer(runner).install(try self.source(yaml), pin: nil, onLine: { _ in }) }
        #expect(runner.commands.isEmpty)
    }

    @Test func unsupportedIsRefused() async throws {
        let yaml = pixalYAML.replacingOccurrences(of: "platform: { status: supported, reason: \"\" }", with: "platform: { status: unsupported, reason: \"needs CUDA\" }")
        let entry = try source(yaml)
        let inst = try installer(FakeRunner())
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .unsupported(reason: "needs CUDA"))
        await #expect(throws: LiftError.prerequisite("Pixal3D is unsupported on this Mac: needs CUDA")) { try await inst.install(entry, pin: nil, onLine: { _ in }) }
    }

    @Test func changedRecipeOrPinMeansUpdateAvailable() async throws {
        let entry = try source()
        let inst = try installer(FakeRunner())
        try await inst.install(entry, pin: nil, onLine: { _ in })
        let other = String(repeating: "b", count: 40)
        #expect(inst.status(id: "pixal3d", source: entry, pin: other) == .updateAvailable(installedCommit: entry.recipe.commit, recipeCommit: other))
        try "def run(state, job):\n    return ['x']\n".write(to: entry.directory.appending(path: "launcher.py"), atomically: true, encoding: .utf8)
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .updateAvailable(installedCommit: entry.recipe.commit, recipeCommit: entry.recipe.commit))
    }

    @Test func pinOverrideIsCheckedOut() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        let pin = String(repeating: "c", count: 40)
        try await inst.install(try source(), pin: pin, onLine: { _ in })
        #expect(runner.displays[2].hasSuffix("checkout --quiet \(pin)"))
    }

    @Test func checkUpstreamCountsCommitsPastThePin() async throws {
        let runner = FakeRunner()
        let head = String(repeating: "d", count: 40)
        runner.on("ls-remote", lines: ["\(head)\tHEAD"])
        runner.on("rev-list --count", lines: ["7"])
        let entry = try source()
        let inst = try installer(runner)
        #expect(try await inst.checkUpstream(entry.recipe, pin: nil) == UpstreamStatus(pin: entry.recipe.commit, head: head, commitsAhead: nil))
        try await inst.install(entry, pin: nil, onLine: { _ in })
        try FileManager.default.createDirectory(at: inst.dir("pixal3d").appending(path: "repo"), withIntermediateDirectories: true)
        #expect(try await inst.checkUpstream(entry.recipe, pin: nil) == UpstreamStatus(pin: entry.recipe.commit, head: head, commitsAhead: 7))
    }

    @Test func aRecipeNeedingTheMetalToolchainChecksItBeforeTouchingAnything() async throws {
        let runner = FakeRunner()
        runner.on("xcrun metal", code: 1)
        let entry = try source(pixalYAML + "\nmetal_toolchain: true\n")
        await #expect(throws: LiftError.self) { try await self.installer(runner).install(entry, pin: nil, onLine: { _ in }) }
        #expect(runner.displays == ["/usr/bin/xcrun metal --version"])
        let ok = FakeRunner()
        try await installer(ok).install(entry, pin: nil, onLine: { _ in })
        #expect(ok.displays.first == "/usr/bin/xcrun metal --version")
    }

    @Test func depsStartsEmptyOnEveryInstall() async throws {
        let inst = try installer(FakeRunner())
        let stale = inst.dir("pixal3d").appending(path: "deps/mtlgemm/build")  // a previous install's build products
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try await inst.install(try source(), pin: nil, onLine: { _ in })
        #expect(!FileManager.default.fileExists(atPath: inst.dir("pixal3d").appending(path: "deps").path))
    }

    @Test func weightDownloadsNameOnlyTheListedFiles() async throws {
        let runner = FakeRunner()
        let yaml = pixalYAML.replacingOccurrences(of: "  - { repo: TencentARC/Pixal3D, gated: false }",
                                                  with: "  - { repo: TencentARC/Pixal3D, gated: false, files: [pipeline.json, ckpts/a.safetensors] }")
        let entry = try source(yaml)
        let inst = try installer(runner)
        let bin = inst.dir("pixal3d").appending(path: "venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin.appending(path: "hf"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "hf").path)
        try await inst.downloadWeights(entry.recipe, onLine: { _ in })
        #expect(runner.displays.first == "\(bin.path)/hf download TencentARC/Pixal3D pipeline.json ckpts/a.safetensors --revision main")
    }

    @Test func downloadWeightsRunsHFFromTheVenv() async throws {
        let runner = FakeRunner()
        let entry = try source()
        let inst = try installer(runner)
        await #expect(throws: LiftError.self) { try await inst.downloadWeights(entry.recipe, onLine: { _ in }) }  // no hf yet
        let bin = inst.dir("pixal3d").appending(path: "venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin.appending(path: "hf"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "hf").path)
        try await inst.downloadWeights(entry.recipe, onLine: { _ in })
        #expect(runner.displays == ["\(bin.path)/hf download TencentARC/Pixal3D --revision main",
                                    "\(bin.path)/hf download briaai/RMBG-2.0 --revision 1f3e2a7c"])
        #expect(runner.commands.allSatisfy { $0.environment["HF_HUB_CACHE"] == "/hf/hub" && $0.environment["HF_TOKEN"] == "hf_x" })
        #expect(try String(contentsOf: inst.logURL("pixal3d"), encoding: .utf8).contains("$ \(bin.path)/hf download TencentARC/Pixal3D"))
        await #expect(throws: LiftError.self) { try await self.installer(runner, token: nil).downloadWeights(entry.recipe, onLine: { _ in }) }
    }

    @Test func uninstallRemovesOnlyTheModelFolder() async throws {
        let entry = try source()
        let inst = try installer(FakeRunner())
        try await inst.install(entry, pin: nil, onLine: { _ in })
        try inst.uninstall("pixal3d")
        #expect(!FileManager.default.fileExists(atPath: inst.dir("pixal3d").path))
        #expect(inst.status(id: "pixal3d", source: entry, pin: nil) == .notInstalled)
    }
}
