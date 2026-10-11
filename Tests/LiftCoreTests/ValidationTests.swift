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

    @Test func hugeOrNonFiniteNumbersAreRejectedNotTrapped() throws {
        let t = try task()
        #expect(fields { _ = try t.validated(settings: ["seed": .float(1e300)], prefix: "s") } == ["s.seed"])  // Int(1e300) would trap
        #expect(fields { _ = try t.validated(settings: ["manual_fov": .float(.infinity)], prefix: "s") } == ["s.manual_fov"])
        #expect(fields { _ = try t.validated(settings: ["manual_fov": .float(.nan)], prefix: "s") } == ["s.manual_fov"])
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

    /// I8: an image_set is a flat folder of images (plus an optional transforms.json), never "/" or a tree.
    @Test func imageSetIsAFlatFolderOfImages() throws {
        var t = try task()
        t.inputs = [TaskInput(name: "views", type: .imageSet)]
        func check(_ path: String, workdir: URL? = nil) -> [String] {
            fields { _ = try t.validated(inputs: ["views": path], chained: false, prefix: "i", workdir: workdir) }
        }
        let dir = try Fixtures.tempDir()
        for name in ["front.png", "right.JPG", "back.jpeg", "left.webp"] { try Data([1]).write(to: dir.appending(path: name)) }
        try Data("{}".utf8).write(to: dir.appending(path: "transforms.json"))
        try Data([0]).write(to: dir.appending(path: ".DS_Store"))  // hidden files are ignored
        #expect(check(dir.path) == [])
        #expect(check(dir.appending(path: "front.png").path) == ["i.views"])  // a file, not a folder
        #expect(check("/") == ["i.views"])
        #expect(check(FileManager.default.homeDirectoryForCurrentUser.path) == ["i.views"])
        let nested = try Fixtures.tempDir()
        try Data([1]).write(to: nested.appending(path: "a.png"))
        try FileManager.default.createDirectory(at: nested.appending(path: "more"), withIntermediateDirectories: true)
        #expect(check(nested.path) == ["i.views"])
        let other = try Fixtures.tempDir()
        try Data([1]).write(to: other.appending(path: "notes.txt"))
        #expect(check(other.path) == ["i.views"])
        #expect(check(try Fixtures.tempDir().path) == ["i.views"])  // empty
        let many = try Fixtures.tempDir()
        for i in 0..<65 { try Data([1]).write(to: many.appending(path: "\(i).png")) }
        #expect(check(many.path) == ["i.views"])
        let parent = try Fixtures.tempDir()
        try Data([1]).write(to: parent.appending(path: "a.png"))
        #expect(check(parent.path, workdir: parent.appending(path: "lift-workdir")) == ["i.views"])  // contains the workdir
    }

    @Test func chainTypes() {
        #expect(IOType.mesh.accepts(.mesh) && IOType.mesh.accepts(.riggedMesh))
        #expect(!IOType.riggedMesh.accepts(.mesh) && !IOType.image.accepts(.mesh))
    }
}
