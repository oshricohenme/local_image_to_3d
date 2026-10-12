import Foundation
import Testing
@testable import LiftCore

/// The real recipes in dev-recipes/: they parse, validate, and install (dry run) exactly as the go/no-go found.
@Suite struct BundledRecipeTests {
    static let catalog = Catalog.scan([RecipeSourceDir(name: "bundled", dir: Fixtures.devRecipes)], includeDeveloper: true)

    func entry(_ id: String) throws -> CatalogEntry { try #require(Self.catalog.entries[id]) }

    func installer(_ runner: FakeRunner, brew: String? = "/opt/homebrew/bin/brew") throws -> Installer {
        Installer(runner: runner, models: try Fixtures.tempDir(), workerRuntime: URL(filePath: "/lift/runtime"),
                  tools: ToolPaths(brew: brew, git: "/bin/git", uv: "/bin/uv"), toolEnvironment: ["PATH": "/bin"],
                  hfToken: { "hf_x" }, hfHub: URL(filePath: "/hf/hub"))
    }

    @Test func everyRecipeParsesAndValidates() throws {
        #expect(Self.catalog.problems.isEmpty, "\(Self.catalog.problems)")
        #expect(Self.catalog.entries.keys.sorted() == ["pixal3d", "test-cube", "trellis2-mac", "unirig"])
        for id in ["pixal3d", "unirig", "trellis2-mac"] {
            let r = try entry(id).recipe
            #expect(r.platform.status == .supported)
            #expect(r.commit?.count == 40)
        }
    }

    @Test func shimConfigsMatchTheGoNoGoFindings() throws {
        let registry = try Substitute.registry(shared: Fixtures.devRecipes.appending(path: "shared"))
        func shim(_ id: String) throws -> String? { try ShimConfig.build(entry(id).recipe, registry: registry)?.json }
        #expect(try shim("pixal3d") == #"{"aliases":{"nvdiffrast":"mtldiffrast"},"env":{},"patches":[],"standins":["flash_attn","natten"]}"#)
        #expect(try shim("unirig") == #"{"aliases":{},"env":{"TORCH_FORCE_NO_WEIGHTS_ONLY_LOAD":"1"},"patches":["transformers_fa2_to_sdpa","torch_scatter_mps","torch_cluster_mps"],"standins":["flash_attn","spconv"]}"#)
        #expect(try shim("trellis2-mac") == nil)
    }

    /// UniRig's FBX writer catches its own error and prints only the message: the launcher passes that on, and a
    /// skeleton with too few bones gets its own plain message instead of the generic skinning one.
    @Test func uniRigSaysWhyTheSkinStepFailed() throws {
        let r = try entry("unirig").recipe
        let few = #"RuntimeError: UniRig generate_skin.sh finished without writing skin.fbx: UniRig said "index 3 is out of bounds for axis 1 with size 3""#
        #expect(r.plainError(few)?.hasPrefix("UniRig's skeleton for this model has only a few bones") == true)
        let other = #"RuntimeError: UniRig generate_skin.sh finished without writing skin.fbx: UniRig said "something else""#
        #expect(r.plainError(other)?.hasPrefix("UniRig made a skeleton but couldn't compute the skinning") == true)
        #expect(r.failureMessage(other).contains(#"UniRig said "something else""#))  // the details keep upstream's words
    }

    /// Every git clone is followed by a checkout of a full sha, and every git+https requirement names one.
    @Test func everyUpstreamSourceIsPinned() throws {
        let registry = try Substitute.registry(shared: Fixtures.devRecipes.appending(path: "shared"))
        let commands = Self.catalog.entries.values.flatMap(\.recipe.install) + registry.values.flatMap(\.install)
        for c in commands where c.contains("git clone") {
            #expect(c.range(of: #"\{ \[ -d (\S+)/\.git \] \|\| git clone --filter=blob:none \S+ \1; \} && git -C \1 fetch -q origin && git -C \1 checkout -qf [0-9a-f]{40}( && git -C \1 clean -fdxq)?$"#,
                            options: .regularExpression) != nil, "\(c)")
        }
        for c in commands where c.contains("git+https") {
            #expect(c.range(of: #"git\+https://[^"@ ]+@[0-9a-f]{40}"#, options: .regularExpression) != nil, "\(c)")
        }
    }

    @Test func pixal3dInstallsInTheFindingsOrder() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        let e = try entry("pixal3d")
        let m = inst.dir("pixal3d").path
        let stale = inst.dir("pixal3d").appending(path: "deps/mtlgemm/build")  // a previous install's build products
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try await inst.install(e, pin: nil, onLine: { _ in })
        #expect(!FileManager.default.fileExists(atPath: stale.path))  // deps/ starts empty, so substitutes rebuild cleanly
        let d = runner.displays
        #expect(d.first == "/usr/bin/xcrun metal --version")
        let venv = try #require(d.firstIndex(of: "/bin/uv venv --python 3.11 \(m)/venv"))
        #expect(d.contains { $0.hasPrefix("/bin/git") && $0.contains("f7cf38429b0bd264f1995f0f8743a88b1c728b94") })  // the pin
        #expect(d[venv + 1] == #"uv pip install "torch==2.11.*" torchvision"#)
        #expect(d.filter { $0.contains("--no-build-isolation deps/") }.map { String($0.split(separator: " ").last!) }
                == ["deps/mtlgemm", "deps/mtldiffrast", "deps/mtlbvh", "deps/mtlmesh", "deps/trellis2-apple/o-voxel"])
        #expect(d.contains("git -C deps/trellis2-apple submodule update --init --depth 1 o-voxel/third_party/eigen"))
        let lastBuild = try #require(d.lastIndex { $0.contains("--no-build-isolation deps/") })
        #expect(d[lastBuild + 1] == "/bin/uv pip install -e \(e.shared.path)/lift_shim")
        #expect(d.last!.hasPrefix("\(m)/venv/bin/python -m lift_worker --check "))
        #expect(runner.commands.last!.environment["LIFT_SHIM"]?.contains(#""nvdiffrast":"mtldiffrast""#) == true)
        #expect(runner.commands[venv + 1].workingDirectory == m && runner.commands[venv + 1].environment["VIRTUAL_ENV"] == "\(m)/venv")
    }

    @Test func unirigInstallsLibusbWithNativeBrewFirst() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        try await inst.install(try entry("unirig"), pin: nil, onLine: { _ in })
        #expect(runner.displays.first == "/opt/homebrew/bin/brew install libusb")
        #expect(runner.displays.contains(#"python -c "import bpy, open3d, torch_scatter, torch_cluster""#))
        #expect(!runner.displays.contains { $0.contains("xcrun metal") })
    }

    @Test func unirigNeedsNativeBrew() async throws {
        let runner = FakeRunner()
        await #expect(throws: LiftError.prerequisite("UniRig needs native Homebrew for libusb; run system_install_prereqs")) {
            try await installer(runner, brew: nil).install(try entry("unirig"), pin: nil, onLine: { _ in })
        }
        #expect(runner.commands.isEmpty)
    }

    @Test func trellisRunsSetupShWithPinsPrePlacedAndNoShim() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        let m = inst.dir("trellis2-mac").path
        try await inst.install(try entry("trellis2-mac"), pin: nil, onLine: { _ in })
        let d = runner.displays
        let setup = try #require(d.firstIndex(of: "cd repo && UV_CONSTRAINT=../torch-constraint.txt UV_NO_CACHE=1 bash setup.sh"))
        for dep in ["TRELLIS.2", "deps/mtlbvh", "deps/mtldiffrast", "deps/mtlmesh", "deps/mtlgemm", "deps/trellis2-apple"] {
            let clone = try #require(d.firstIndex { $0.contains("git clone --filter=blob:none") && $0.contains(" repo/\(dep); }") }, "\(dep)")
            #expect(clone < setup)
        }
        #expect(d.firstIndex(of: "ln -sfn ../venv repo/.venv")! < setup)
        // Lift owns these nested clones: every install resets them to the pin, and setup.sh re-applies its patches.
        #expect(d.filter { $0.contains("git clone") && $0.contains(" repo/") }.allSatisfy { $0.hasSuffix("clean -fdxq") })
        #expect(d.firstIndex(of: "printf 'torch==2.13.0\\n' > torch-constraint.txt")! < setup)
        #expect(!d.contains { $0.contains("lift_shim") })
        #expect(runner.commands.last!.environment["LIFT_SHIM"] == nil)
        #expect(d.last!.hasPrefix("\(m)/venv/bin/python -m lift_worker --check "))
    }

    @Test func aMissingMetalToolchainStopsBeforeAnythingIsTouched() async throws {
        let runner = FakeRunner()
        runner.on("xcrun metal", code: 1)
        await #expect(throws: LiftError.prerequisite("TRELLIS.2 (Mac) needs Apple's Metal Toolchain; install it from Setup (system_install_prereqs with metal)")) {
            try await installer(runner).install(try entry("trellis2-mac"), pin: nil, onLine: { _ in })
        }
        #expect(runner.displays == ["/usr/bin/xcrun metal --version"])
    }

    @Test func weightDownloadsFetchOnlyTheListedFiles() async throws {
        let runner = FakeRunner()
        let inst = try installer(runner)
        let bin = inst.dir("unirig").appending(path: "venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: bin.appending(path: "hf"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "hf").path)
        try await inst.downloadWeights(try entry("unirig").recipe, onLine: { _ in })
        #expect(runner.displays == [
            "\(bin.path)/hf download VAST-AI/UniRig skeleton/articulation-xl_quantization_256/model.ckpt skin/articulation-xl/model.ckpt --revision main",
            "\(bin.path)/hf download facebook/opt-350m config.json --revision main",
        ])
        // Plain HTTP, not hf_xet: xet held ~1 GB per file in memory (5 GB for Pixal3D), wrote in bursts (the bar
        // froze), and a pause or relaunch threw the memory away and rewrote files from earlier on (first real run).
        #expect(runner.commands.allSatisfy { $0.environment["HF_HUB_DISABLE_XET"] == "1" })
    }

    /// Spec §4a: every weights repo is credited, and RMBG-2.0's non-commercial license is flagged wherever it's used.
    @Test func everyRecipeCreditsWhatItUses() throws {
        for id in ["pixal3d", "unirig", "trellis2-mac"] {
            let r = try entry(id).recipe
            let a = r.attribution
            #expect(a.problems.isEmpty && a.paper != nil, "\(id): \(a.problems)")
            for w in r.weights {
                #expect(a.components.contains { $0.url.absoluteString == "https://huggingface.co/\(w.repo)" }, "\(id): \(w.repo) is not credited")
            }
            for c in a.components where c.name.hasPrefix("RMBG-2.0") { #expect(c.restrictions == ["non-commercial"], "\(id)") }
            #expect(r.description?.isEmpty == false && !r.errors.isEmpty, "\(id) needs plain-language copy")
            for task in r.tasks {
                let basic = task.settings.filter { $0.group == "basic" }
                #expect((2...4).contains(basic.count), "\(id)/\(task.id): \(basic.count) basic settings")
                #expect(task.settings.allSatisfy { $0.help?.isEmpty == false }, "\(id)/\(task.id): every setting has help")
            }
        }
        #expect(try entry("trellis2-mac").recipe.attribution.components.contains { $0.url.absoluteString == "https://github.com/shivampkumar/trellis-mac" })
    }

    @Test func gatedWeightsAreMarked() throws {
        func gated(_ id: String) throws -> [String] { try entry(id).recipe.weights.filter(\.gated).map(\.repo) }
        #expect(try gated("pixal3d") == ["briaai/RMBG-2.0"])
        #expect(try gated("trellis2-mac") == ["facebook/dinov3-vitl16-pretrain-lvd1689m", "briaai/RMBG-2.0"])
        #expect(try gated("unirig").isEmpty)
        #expect(try entry("unirig").recipe.weights.first { $0.repo == "facebook/opt-350m" }?.files == ["config.json"])

    }

    /// Only a real Hugging Face auth failure blames access; numbers in an unrelated crash's log don't.
    @Test func huggingFaceAccessMessageNeedsARealAuthFailure() throws {
        for id in ["pixal3d", "trellis2-mac"] {
            let r = try entry(id).recipe
            let crash = r.plainError("worker exited with code 137", log: ["Mesh: 1,403,221 vertices, 2,806,401 faces", "Baking: 401/1024"])
            #expect(crash?.contains("Hugging Face") != true, "\(id): \(crash ?? "")")
            for line in ["huggingface_hub.errors.GatedRepoError: 403 Client Error. Cannot access gated repo for url https://huggingface.co/briaai/RMBG-2.0",
                         "requests.exceptions.HTTPError: 401 Client Error: Unauthorized for url: https://huggingface.co/x",
                         "Access to model briaai/RMBG-2.0 is restricted. You must have access to it and be authenticated to access it."] {
                #expect(r.plainError("worker exited with code 1", log: [line])?.contains("Hugging Face") == true, "\(id): \(line)")
            }
        }
    }
}
