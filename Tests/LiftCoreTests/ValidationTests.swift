import Foundation
import Testing
@testable import LiftCore

@Suite struct ValidationTests {
    func task() throws -> RecipeTask {
        let folder = try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())
        guard case .ok(let r) = RecipeLoad.read(directory: folder) else { throw LiftError.invalidState("fixture") }
        return r.tasks[0]
    }

    func fields(_ body: () throws -> Void) -> [String] {
        do { try body() } catch let LiftError.invalidInput(errors) { return errors.map(\.field) } catch { return ["unexpected \(error)"] }
        return []
    }

    @Test func defaultsAreFilled() throws {
        let s = try task().validated(settings: [:], prefix: "settings")
        #expect(s == ["resolution": .int(1536), "low_vram": .bool(false), "seed": .int(42), "manual_fov": .float(-1), "ss_sampling_steps": .int(12)])
    }

    @Test func valuesAreCoerced() throws {
        let s = try task().validated(settings: ["resolution": .float(1024), "manual_fov": .int(1), "seed": .float(7)], prefix: "settings")
        #expect(s["resolution"] == .int(1024) && s["manual_fov"] == .float(1) && s["seed"] == .int(7))
    }

    @Test func badValuesNameTheirFields() throws {
        let t = try task()
        #expect(fields { _ = try t.validated(settings: ["resolution": .int(999)], prefix: "s") } == ["s.resolution"])
        #expect(fields { _ = try t.validated(settings: ["ss_sampling_steps": .int(0)], prefix: "s") } == ["s.ss_sampling_steps"])
        #expect(fields { _ = try t.validated(settings: ["seed": .float(1.5)], prefix: "s") } == ["s.seed"])
        #expect(fields { _ = try t.validated(settings: ["low_vram": .string("yes")], prefix: "s") } == ["s.low_vram"])
        #expect(fields { _ = try t.validated(settings: ["bogus": .int(1), "seed": .string("x")], prefix: "s") } == ["s.bogus", "s.seed"])
    }

    @Test func requiredWithoutDefault() throws {
        var t = try task()
        t.settings.append(SettingDef(key: "prompt", label: "Prompt", type: .string))
        #expect(fields { _ = try t.validated(settings: [:], prefix: "s") } == ["s.prompt"])
    }

    @Test func inputs() throws {
        let t = try task()
        let dir = try Fixtures.tempDir()
        let file = dir.appending(path: "a.png")
        try Data([1]).write(to: file)
        #expect(try t.validated(inputs: ["image": file.path], chained: false, prefix: "i") == ["image": file.path])
        #expect(fields { _ = try t.validated(inputs: [:], chained: false, prefix: "i") } == ["i.image"])
        #expect(try t.validated(inputs: [:], chained: true, prefix: "i") == [:])  // filled from the previous step
        #expect(fields { _ = try t.validated(inputs: ["image": dir.appending(path: "missing.png").path], chained: false, prefix: "i") } == ["i.image"])
        #expect(fields { _ = try t.validated(inputs: ["image": dir.path], chained: false, prefix: "i") } == ["i.image"])  // a folder, not a file
        #expect(fields { _ = try t.validated(inputs: ["image": file.path, "extra": file.path], chained: false, prefix: "i") } == ["i.extra"])
    }

    @Test func imageSetNeedsAFolder() throws {
        var t = try task()
        t.inputs = [TaskInput(name: "views", type: .imageSet)]
        let dir = try Fixtures.tempDir()
        #expect(try t.validated(inputs: ["views": dir.path], chained: false, prefix: "i") == ["views": dir.path])
        let file = dir.appending(path: "a.png")
        try Data([1]).write(to: file)
        #expect(fields { _ = try t.validated(inputs: ["views": file.path], chained: false, prefix: "i") } == ["i.views"])
    }

    @Test func chainTypes() {
        #expect(IOType.mesh.accepts(.mesh) && IOType.mesh.accepts(.riggedMesh))
        #expect(!IOType.riggedMesh.accepts(.mesh) && !IOType.image.accepts(.mesh))
    }
}
