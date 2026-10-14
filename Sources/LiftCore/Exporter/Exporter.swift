import CryptoKit
import Foundation
import GLTFKit2
import ModelIO
import SceneKit

public enum ExportFormat: String, Codable, Sendable, CaseIterable {
    case glb, usdz, obj, fbx, original
}

/// A job's `export` (spec §7). In a request, nil fields take the `export_dir`, `export_formats` and
/// `cleanup_after_export` settings; the stored job has all three filled.
public struct ExportSpec: Codable, Sendable, Equatable {
    public var dir: String?
    public var formats: [ExportFormat]?
    public var cleanupAfterExport: Bool?

    public init(dir: String? = nil, formats: [ExportFormat]? = nil, cleanupAfterExport: Bool? = nil) {
        self.dir = dir
        self.formats = formats
        self.cleanupAfterExport = cleanupAfterExport
    }
}

/// One format's outcome. A failed format never affects the others (spec §9).
public struct ExportResult: Codable, Sendable, Equatable {
    public var format: ExportFormat
    /// What landed in the export folder: a file, or for OBJ a folder with the .obj, its .mtl and textures.
    public var path: String?
    public var error: String?
    /// The `<title>.credits.txt` next to it (USDZ, OBJ and FBX carry no attribution of their own).
    public var credits: String?
}

/// Converts a job's final output and copies it into the export folder as `<title>.<ext>` (spec §9):
/// GLB as is, USDZ through SceneKit, OBJ through ModelIO (GLB read by GLTFKit2), FBX through Blender's `bpy`.
/// Every export credits the models that made it (spec §4a): in the GLB's `asset` fields, and in a
/// `<title>.credits.txt` sidecar for the other formats.
public struct Exporter: Sendable {
    let runner: any CommandRunner
    /// A Python with Blender's `bpy` (the UniRig venv); nil when there is none.
    let blenderPython: String?

    public init(runner: any CommandRunner, blenderPython: String?) {
        self.runner = runner
        self.blenderPython = blenderPython
    }

    /// `work` is scratch space inside the job folder; `outputs` are the final step's files; `credits` are the
    /// attributions of the recipes that made them, in step order.
    public func export(_ outputs: [String], title: String, formats: [ExportFormat], credits: [Attribution],
                       to dir: URL, work: URL) async -> [ExportResult] {
        var results: [ExportResult] = []
        let name = Self.fileName(title)
        for format in formats where !results.contains(where: { $0.format == format }) {
            do {
                var made = try await convert(outputs, to: format, name: name, in: work.appending(path: format.rawValue))
                if format == .glb, !credits.isEmpty {
                    let stamped = work.appending(path: "glb-credited/\(made.lastPathComponent)")
                    try FileManager.default.createDirectory(at: stamped.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Self.stamped(glb: Data(contentsOf: made), credit: Self.creditLine(credits)).write(to: stamped)
                    made = stamped
                }
                results.append(ExportResult(format: format, path: try Self.copy(made, into: dir).path))
            } catch {
                results.append(ExportResult(format: format, error: "\(error)"))
            }
        }
        if !credits.isEmpty, results.contains(where: { $0.format != .glb && $0.path != nil }) {
            let sidecar = work.appending(path: "\(name).credits.txt")
            do {
                try Self.creditsText(credits).write(to: sidecar, atomically: true, encoding: .utf8)
                let copied = try Self.copy(sidecar, into: dir).path
                for i in results.indices where results[i].format != .glb && results[i].path != nil { results[i].credits = copied }
            } catch {
                for i in results.indices where results[i].format != .glb && results[i].path != nil { results[i].error = "credits file: \(error)" }
            }
        }
        return results
    }

    /// "<Project> by <authors> (<license>); …, run with Lift" (spec §4a).
    static func creditLine(_ credits: [Attribution]) -> String {
        credits.map(\.credit).joined(separator: "; ") + ", run with Lift"
    }

    /// The sidecar: the credit line, each project's disclaimer and its components with their licenses.
    static func creditsText(_ credits: [Attribution]) -> String {
        var lines = [creditLine(credits), ""]
        for a in credits {
            lines += [a.disclaimer, "\(a.project): \(a.homepage) — \(a.license.spdx) (\(a.license.url))"]
            for c in a.components {
                let restricted = (c.restrictions ?? []).isEmpty ? "" : " — \((c.restrictions ?? []).joined(separator: ", ").uppercased())"
                lines.append("  - \(c.name): \(c.url) — \(c.license.spdx) (\(c.license.url))\(restricted)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// The GLB with `asset.copyright` and `asset.generator` set to `credit`; its binary chunk is untouched.
    static func stamped(glb data: Data, credit: String) throws -> Data {
        let b = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        guard b.count >= 20, u32(0) == 0x4654_6C67, u32(16) == 0x4E4F_534A, 20 + u32(12) <= b.count else {
            throw LiftError.invalidState("not a binary glTF file")
        }
        let jsonEnd = 20 + u32(12)
        guard var json = try JSONSerialization.jsonObject(with: Data(b[20..<jsonEnd])) as? [String: Any] else {
            throw LiftError.invalidState("the GLB's JSON is not an object")
        }
        var asset = json["asset"] as? [String: Any] ?? ["version": "2.0"]
        asset["copyright"] = credit
        asset["generator"] = credit
        json["asset"] = asset
        var text = try JSONSerialization.data(withJSONObject: json, options: [.withoutEscapingSlashes])
        while text.count % 4 != 0 { text.append(0x20) }
        var out = Data()
        func put(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { out.append(contentsOf: $0) } }
        put(0x4654_6C67); put(2); put(12 + 8 + text.count + (b.count - jsonEnd))
        put(text.count); put(0x4E4F_534A)
        out.append(text)
        out.append(contentsOf: b[jsonEnd...])
        return out
    }

    func convert(_ outputs: [String], to format: ExportFormat, name: String, in work: URL) async throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let files = outputs.map { URL(filePath: $0) }
        if format == .original {
            guard !files.isEmpty else { throw LiftError.invalidState("no output files to export") }
            // Keep multi-file results together: separated audio stems and sidecars must survive cleanup.
            let folder = work.appending(path: name)
            if fm.fileExists(atPath: folder.path) { try fm.removeItem(at: folder) }
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for file in files { _ = try Self.copy(file, into: folder) }
            return folder
        }
        // The primary output (the first) is used as is when it's already in this format, e.g. UniRig's rigged FBX.
        // Only the primary: UniRig's later outputs are intermediate skin/skeleton passes, not the rigged model.
        // OBJ is always made from the GLB: an upstream OBJ (trellis-mac's) is bare geometry.
        if format != .obj, let primary = files.first, primary.pathExtension.lowercased() == format.rawValue {
            let dest = work.appending(path: "\(name).\(format.rawValue)")
            try fm.copyItem(at: primary, to: dest)
            return dest
        }
        var glb = files.first(where: { $0.pathExtension.lowercased() == "glb" })
        if glb == nil, let primary = files.first, primary.pathExtension.lowercased() == "fbx" {
            guard blenderPython != nil else {
                throw LiftError.prerequisite("This model was saved as FBX only. Choose FBX in the export formats, or set UniRig's File type to GLB.")
            }
            // ponytail: one Blender run per format that needs the GLB; share it if several formats get slow.
            glb = try await blender(primary, to: work.appending(path: "from-fbx/\(name).glb"), work: work)
        }
        guard let glb else {
            throw LiftError.invalidState("no GLB output to make \(format.rawValue) from")
        }
        switch format {
        case .original:
            throw LiftError.invalidState("original export was not handled")
        case .glb:
            let dest = work.appending(path: "\(name).glb")
            try fm.copyItem(at: glb, to: dest)
            return dest
        case .usdz:
            // ModelIO can't write USDZ, and its USDC loses texture references; SceneKit embeds them.
            let dest = work.appending(path: "\(name).usdz")
            guard SCNScene(gltfAsset: try GLTFAsset(url: glb)).write(to: dest, options: nil, delegate: nil, progressHandler: nil) else {
                throw LiftError.invalidState("SceneKit could not write \(dest.lastPathComponent)")
            }
            return dest
        case .obj:
            // ModelIO writes the .mtl and textures next to the .obj and names textures after materials,
            // so the three travel as one folder and two exports never overwrite each other's textures.
            let folder = work.appending(path: name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try MDLAsset(gltfAsset: try GLTFAsset(url: glb)).export(to: folder.appending(path: "\(name).obj"))
            return folder
        case .fbx:
            guard blenderPython != nil else {
                throw LiftError.prerequisite("FBX export uses Blender's bpy from the UniRig model; install UniRig to export FBX")
            }
            return try await blender(glb, to: work.appending(path: "\(name).fbx"), work: work)
        }
    }

    /// Converts between GLB and FBX with Blender (`blenderPython` must be set).
    func blender(_ source: URL, to dest: URL, work: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await runner.check(ShellCommand(blenderPython!, ["-c", Self.blenderScript, source.path, dest.path],
                                            environment: ["BLENDER_USER_RESOURCES": work.appending(path: "blender").path]))
        guard FileManager.default.fileExists(atPath: dest.path) else { throw LiftError.invalidState("Blender wrote no \(dest.lastPathComponent)") }
        return dest
    }

    /// Blender's own glTF and FBX importers and exporters, picked by extension; armatures and skin weights carry
    /// over, textures are embedded. bpy 4.2 as a Python module segfaults at interpreter exit (code 139), hence
    /// `os._exit(0)` once written.
    static let blenderScript = """
    import os, sys
    import bpy
    source, target = sys.argv[-2], sys.argv[-1]
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if source.lower().endswith(".fbx"):
        bpy.ops.import_scene.fbx(filepath=source)
    else:
        bpy.ops.import_scene.gltf(filepath=source)
    if target.lower().endswith(".fbx"):
        bpy.ops.export_scene.fbx(filepath=target, path_mode="COPY", embed_textures=True, add_leaf_bones=False)
    else:
        bpy.ops.export_scene.gltf(filepath=target, export_format="GLB")
    sys.stdout.flush()
    os._exit(0)
    """

    /// A title made safe for a file name: no `/` or `:`, no leading dot.
    static func fileName(_ title: String) -> String {
        let cleaned = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return cleaned.isEmpty ? "export" : cleaned
    }

    /// Copies a file or folder into `dir` without overwriting (`name 2.ext`, `name 3.ext`, …) and checks
    /// the copy's SHA-256 against the source.
    static func copy(_ item: URL, into dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let needed = try size(item)
        if let free = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < needed {
            throw LiftError.prerequisite("not enough disk space in \(dir.path): \(needed) bytes needed, \(free) free")
        }
        let ext = item.pathExtension, stem = item.deletingPathExtension().lastPathComponent
        var dest = dir.appending(path: item.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = dir.appending(path: ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
            n += 1
        }
        try fm.copyItem(at: item, to: dest)
        guard try digest(item) == digest(dest) else {
            try? fm.removeItem(at: dest)
            throw LiftError.invalidState("the copy at \(dest.path) does not match its source")
        }
        return dest
    }

    /// Files in `item` (or `item` itself), as sorted relative paths.
    static func files(_ item: URL) -> [String] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue else { return [""] }
        return (FileManager.default.subpaths(atPath: item.path) ?? []).filter { path in
            var d: ObjCBool = false
            return FileManager.default.fileExists(atPath: item.appending(path: path).path, isDirectory: &d) && !d.boolValue
        }.sorted()
    }

    static func size(_ item: URL) throws -> Int {
        try files(item).reduce(0) { total, path in
            let url = path.isEmpty ? item : item.appending(path: path)
            return total + (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
    }

    static func digest(_ item: URL) throws -> String {
        var hash = SHA256()
        for path in files(item) {
            hash.update(data: Data(path.utf8))
            hash.update(data: try Data(contentsOf: path.isEmpty ? item : item.appending(path: path), options: .mappedIfSafe))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
