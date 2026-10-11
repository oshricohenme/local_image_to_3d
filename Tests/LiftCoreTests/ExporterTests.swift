import Foundation
import ModelIO
import Testing
@testable import LiftCore

/// A recipe's attribution as Lift reads it, with one restricted component.
let cubeCredits = [try! attribution(cubeAttributionJSON)]

@Suite struct ExporterTests {
    /// A stand-in for the UniRig venv's python: writes its last argument (the FBX path) like Blender would.
    func fakeBlender() throws -> String {
        let bin = try Fixtures.fakeBin(["python"]).appending(path: "python")
        try "#!/bin/sh\nfor a; do last=\"$a\"; done\necho fbx > \"$last\"\n".write(to: bin, atomically: true, encoding: .utf8)
        return bin.path
    }

    func export(_ outputs: [URL], _ formats: [ExportFormat], title: String = "My cube", blender: String? = nil,
                runner: any CommandRunner = SubprocessRunner(), into dir: URL? = nil,
                credits: [Attribution] = cubeCredits) async throws -> (URL, [ExportResult]) {
        let dir = try dir ?? Fixtures.tempDir()
        let results = await Exporter(runner: runner, blenderPython: blender)
            .export(outputs.map(\.path), title: title, formats: formats, credits: credits, to: dir, work: try Fixtures.tempDir())
        return (dir, results)
    }

    /// The GLB's JSON chunk as a dictionary, and everything after it (the binary chunk).
    func glbParts(_ url: URL) throws -> (json: [String: Any], rest: Data) {
        let b = [UInt8](try Data(contentsOf: url))
        let end = 20 + (Int(b[12]) | Int(b[13]) << 8 | Int(b[14]) << 16 | Int(b[15]) << 24)
        return (try JSONSerialization.jsonObject(with: Data(b[20..<end])) as! [String: Any], Data(b[end...]))
    }

    @Test func glbKeepsItsGeometryAndCarriesTheCredit() async throws {
        let glb = try Fixtures.cubeGLB(textured: true)
        let (dir, results) = try await export([glb], [.glb])
        let out = dir.appending(path: "My cube.glb")
        #expect(results == [ExportResult(format: .glb, path: out.path)])
        let asset = try #require(try glbParts(out).json["asset"] as? [String: Any])
        #expect(asset["copyright"] as? String == "Test Cube by Lift (MIT), run with Lift" && asset["generator"] as? String == asset["copyright"] as? String)
        #expect(asset["version"] as? String == "2.0")
        #expect(try Data(contentsOf: out).count % 4 == 0)
        #expect(try glbParts(out).rest == glbParts(glb).rest)  // the binary chunk is untouched
        #expect((try glbParts(out).json["meshes"] as? [Any])?.count == 1)  // the rest of the JSON is intact
    }

    @Test func otherFormatsGetACreditsSidecar() async throws {
        let (dir, results) = try await export([try Fixtures.cubeGLB()], [.glb, .obj, .usdz])
        let sidecar = dir.appending(path: "My cube.credits.txt")
        #expect(results[0].credits == nil && results[1].credits == sidecar.path && results[2].credits == sidecar.path)
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(text.hasPrefix("Test Cube by Lift (MIT), run with Lift\n"))
        #expect(text.contains("Lift did not create Test Cube and is not affiliated with or endorsed by its authors."))
        #expect(text.contains("RMBG-2.0: https://huggingface.co/briaai/RMBG-2.0 — CC-BY-NC-4.0") && text.contains("NON-COMMERCIAL"))
        let (glbOnly, _) = try await export([try Fixtures.cubeGLB()], [.glb])
        #expect(!FileManager.default.fileExists(atPath: glbOnly.appending(path: "My cube.credits.txt").path))  // the GLB credits itself
    }

    @Test func usdzEmbedsTheTexture() async throws {
        let (dir, results) = try await export([try Fixtures.cubeGLB(textured: true)], [.usdz])
        let usdz = dir.appending(path: "My cube.usdz")
        #expect(results.first?.error == nil && results.first?.path == usdz.path)
        let bytes = try Data(contentsOf: usdz)
        #expect(bytes.prefix(2) == Data("PK".utf8))  // a zip package
        #expect(bytes.range(of: Data(".png".utf8)) != nil)  // the base-color texture travels inside
        #expect(MDLAsset(url: usdz).count == 1)
    }

    @Test func objIsAFolderWithItsMaterialAndTexture() async throws {
        let (dir, results) = try await export([try Fixtures.cubeGLB(textured: true)], [.obj])
        let folder = dir.appending(path: "My cube")
        #expect(results.first?.path == folder.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(files.contains("My cube.obj") && files.contains("My cube.mtl") && files.contains { $0.hasSuffix(".png") })
        let obj = MDLAsset(url: folder.appending(path: "My cube.obj"))
        #expect((obj.object(at: 0) as? MDLMesh)?.vertexCount ?? 0 >= 8)
    }

    @Test func fbxRunsBlendersImporterAndExporter() async throws {
        let blender = try fakeBlender()
        let glb = try Fixtures.cubeGLB()
        let runner = RecordingRunner()
        let (dir, results) = try await export([glb], [.fbx], blender: blender, runner: runner)
        #expect(results.first?.path == dir.appending(path: "My cube.fbx").path)
        let command = try #require(runner.commands.first)
        #expect(command.executable == blender && command.arguments[0] == "-c" && command.arguments[1] == Exporter.fbxScript)
        #expect(command.arguments[2] == glb.path && command.arguments[3].hasSuffix("/fbx/My cube.fbx"))
        #expect(command.environment["BLENDER_USER_RESOURCES"]?.hasSuffix("/fbx/blender") == true)
    }

    @Test func eachFormatFailsAlone() async throws {
        let (dir, results) = try await export([try Fixtures.cubeGLB()], [.glb, .fbx, .obj])
        #expect(results.map(\.format) == [.glb, .fbx, .obj])
        #expect(results[1].path == nil && results[1].error?.contains("install UniRig") == true)
        #expect(results[0].error == nil && results[2].error == nil)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "My cube.glb").path))
    }

    @Test func anOutputAlreadyInTheFormatIsUsedAsIs() async throws {
        let fbx = try Fixtures.tempDir().appending(path: "rigged.fbx")
        try Data("unirig fbx".utf8).write(to: fbx)
        let runner = RecordingRunner()
        let (dir, results) = try await export([fbx], [.fbx, .usdz], runner: runner)
        #expect(results[0].path == dir.appending(path: "My cube.fbx").path && runner.commands.isEmpty)
        #expect(results[1].error == "no GLB output to make usdz from")
    }

    @Test func existingFilesAreNeverOverwritten() async throws {
        let glb = try Fixtures.cubeGLB()
        let (dir, _) = try await export([glb], [.glb, .obj])
        let (_, again) = try await export([glb], [.glb, .obj], into: dir)
        #expect(again.map(\.path) == [dir.appending(path: "My cube 2.glb").path, dir.appending(path: "My cube 2").path])
    }

    @Test func titlesBecomeSafeFileNames() {
        #expect(Exporter.fileName("chair/v2: final") == "chair-v2- final")
        #expect(Exporter.fileName("  ..hidden ") == "hidden")
        #expect(Exporter.fileName("/") == "-")
        #expect(Exporter.fileName("") == "export")
    }

    /// Real Blender: set LIFT_TEST_BPY_PYTHON to a Python with bpy 4.2 (e.g. an installed UniRig's venv/bin/python).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIFT_TEST_BPY_PYTHON"] != nil))
    func realBlenderWritesAnFBX() async throws {
        let python = ProcessInfo.processInfo.environment["LIFT_TEST_BPY_PYTHON"]!
        let (dir, results) = try await export([try Fixtures.cubeGLB(textured: true)], [.fbx], blender: python)
        #expect(results.first?.error == nil)
        let fbx = try Data(contentsOf: dir.appending(path: "My cube.fbx"))
        #expect(fbx.prefix(18) == Data("Kaydara FBX Binary".utf8))
    }
}

/// Records commands and runs them for real (so the fake Blender writes its file).
final class RecordingRunner: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ShellCommand] = []
    var commands: [ShellCommand] { lock.withLock { recorded } }

    func run(_ command: ShellCommand, onLine: @escaping @Sendable (String) -> Void) async throws -> Int32 {
        lock.withLock { recorded.append(command) }
        return try await SubprocessRunner().run(command, onLine: onLine)
    }
}
