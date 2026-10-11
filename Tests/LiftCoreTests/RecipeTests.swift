import Foundation
import Testing
@testable import LiftCore

/// Writes `<dir>/<id>/recipe.yaml` (+ launcher.py) and returns the folder.
func writeRecipe(_ yaml: String, id: String, in dir: URL, launcher: Bool = true) throws -> URL {
    let folder = dir.appending(path: id)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try yaml.write(to: folder.appending(path: "recipe.yaml"), atomically: true, encoding: .utf8)
    if launcher { try "def run(state, job):\n    return []\n".write(to: folder.appending(path: "launcher.py"), atomically: true, encoding: .utf8) }
    return folder
}

let pixalYAML = """
schema: 1
id: pixal3d
name: Pixal3D
publisher: TencentARC
license: MIT
homepage: https://github.com/TencentARC/Pixal3D
repo: https://github.com/TencentARC/Pixal3D
commit: f7cf38429b0bd264f1995f0f8743a88b1c728b94
python: "3.11"
platform: { status: supported, reason: "" }
install:
  - uv pip install torch torchvision
substitutes: [flash_attn]
shim: { patches: [transformers_fa2_to_sdpa], env: { ATTN_BACKEND: sdpa } }
brew: [libusb]
weights:
  - { repo: TencentARC/Pixal3D, gated: false }
  - { repo: briaai/RMBG-2.0, revision: 1f3e2a7c, gated: true }
resources:
  memory_gb: 18
  memory_keys: [low_vram, resolution]
  memory_overrides: [{ when: { low_vram: true }, memory_gb: 12 }]
  max_concurrent_per_process: 1
stages:
  - { pattern: '^\\[Stage\\] (?P<name>.+)$' }
tasks:
  - id: image_to_3d
    modality: 3d
    label: Image → 3D
    inputs: [{ name: image, type: image }]
    output: mesh
    entry: inference:run_inference
    settings:
      - { key: resolution, label: Resolution, type: enum, options: [1024, 1536], default: 1536, group: basic }
      - { key: low_vram, label: Low memory mode, type: bool, default: false, group: basic }
      - { key: seed, label: Seed, type: int, default: 42, group: basic }
      - { key: manual_fov, label: Camera FOV, type: float, default: -1.0, help: "radians; <0 = auto", group: basic }
      - { key: ss_sampling_steps, label: Sparse structure steps, type: int, min: 1, max: 50, default: 12, group: advanced }
"""

@Suite struct RecipeTests {
    @Test func parsesTheSpecExample() throws {
        let folder = try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())
        guard case .ok(let r) = RecipeLoad.read(directory: folder) else { Issue.record("\(RecipeLoad.read(directory: folder))"); return }
        #expect(r.commit == "f7cf38429b0bd264f1995f0f8743a88b1c728b94")
        #expect(r.substitutes == ["flash_attn"] && r.brew == ["libusb"] && !r.developer)
        #expect(r.shim?.patches == ["transformers_fa2_to_sdpa"] && r.shim?.env == ["ATTN_BACKEND": "sdpa"] && r.shim?.aliases == [:])
        #expect(r.weights == [Recipe.Weight(repo: "TencentARC/Pixal3D"), Recipe.Weight(repo: "briaai/RMBG-2.0", revision: "1f3e2a7c", gated: true)])
        #expect(r.resources.memoryOverrides == [Recipe.MemoryOverride(when: ["low_vram": .bool(true)], memoryGB: 12)])
        #expect(r.resources.diskGB == 5)  // default
        let t = try #require(r.task("image_to_3d"))
        #expect(t.output == .mesh && t.inputs == [TaskInput(name: "image", type: .image)])
        #expect(t.settings.first?.options == [.int(1024), .int(1536)])
        #expect(t.settings.first { $0.key == "manual_fov" }?.default == .float(-1.0))
        #expect(r.stages == [Recipe.StagePattern(pattern: #"^\[Stage\] (?P<name>.+)$"#)])
    }

    @Test func newerSchemaIsReportedNotParsed() throws {
        let folder = try writeRecipe("schema: 2\nid: future\nsomething_new: true\n", id: "future", in: try Fixtures.tempDir())
        #expect(RecipeLoad.read(directory: folder) == .needsNewerLift(id: "future", schema: 2))
    }

    @Test(arguments: [
        ("id: pixal3d", "id: other", "must match its folder"),
        ("commit: f7cf38429b0bd264f1995f0f8743a88b1c728b94", "commit: f7cf384", "40-character"),
        ("type: enum, options: [1024, 1536], default: 1536", "type: enum, default: 1536", "enum needs options"),
        ("min: 1, max: 50, default: 12", "min: 1, max: 50, default: 99", "default must be ≤ 50"),
        ("memory_keys: [low_vram, resolution]", "memory_keys: [low_vram, nope]", "nope is not a setting"),
        ("platform: { status: supported, reason: \"\" }", "platform: { status: unsupported }", "reason is required"),
        ("repo: TencentARC/Pixal3D, gated", "repo: Pixal3D, gated", "must be owner/name"),
    ])
    func invalidRecipes(original: String, replacement: String, message: String) throws {
        let yaml = pixalYAML.replacingOccurrences(of: original, with: replacement)
        let folder = try writeRecipe(yaml, id: "pixal3d", in: try Fixtures.tempDir())
        guard case .invalid(let problems) = RecipeLoad.read(directory: folder) else { Issue.record("expected invalid"); return }
        #expect(problems.contains(message))
    }

    @Test func noShimMeansNone() throws {
        let yaml = pixalYAML.replacingOccurrences(of: "shim: { patches: [transformers_fa2_to_sdpa], env: { ATTN_BACKEND: sdpa } }\n", with: "")
        guard case .ok(let r) = RecipeLoad.read(directory: try writeRecipe(yaml, id: "pixal3d", in: try Fixtures.tempDir())) else { Issue.record("expected ok"); return }
        #expect(r.shim == nil)
    }

    @Test func missingLauncherIsInvalid() throws {
        let folder = try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir(), launcher: false)
        guard case .invalid(let problems) = RecipeLoad.read(directory: folder) else { Issue.record("expected invalid"); return }
        #expect(problems.contains("launcher.py is missing"))
    }

    @Test func undecodableYAMLIsInvalid() throws {
        let folder = try writeRecipe("schema: 1\nid: x\n", id: "x", in: try Fixtures.tempDir())
        guard case .invalid(let problems) = RecipeLoad.read(directory: folder) else { Issue.record("expected invalid"); return }
        #expect(problems.hasPrefix("recipe.yaml:"))
    }
}
