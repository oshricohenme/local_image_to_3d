import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

extension Fixtures {
    /// Writes a 1-unit cube as binary glTF 2.0 (8 vertices, 12 triangles). With `textured`, it also has
    /// UVs and an embedded 2×2 PNG base-color texture, so exporters have a material to carry over.
    static func cubeGLB(textured: Bool = false, in dir: URL? = nil, name: String = "cube.glb") throws -> URL {
        let p: [Float] = [-0.5, -0.5, -0.5, 0.5, -0.5, -0.5, 0.5, 0.5, -0.5, -0.5, 0.5, -0.5,
                          -0.5, -0.5, 0.5, 0.5, -0.5, 0.5, 0.5, 0.5, 0.5, -0.5, 0.5, 0.5]
        let idx: [UInt16] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4,
                             2, 3, 7, 2, 7, 6, 1, 2, 6, 1, 6, 5, 3, 0, 4, 3, 4, 7]
        let uv: [Float] = [0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1]
        var bin = Data()
        func append<T>(_ values: [T]) -> (offset: Int, length: Int) {
            while bin.count % 4 != 0 { bin.append(0) }
            let offset = bin.count
            values.withUnsafeBytes { bin.append(contentsOf: $0) }
            return (offset, bin.count - offset)
        }
        let pv = append(p), iv = append(idx)
        var views: [[String: Any]] = [["buffer": 0, "byteOffset": pv.offset, "byteLength": pv.length, "target": 34962],
                                      ["buffer": 0, "byteOffset": iv.offset, "byteLength": iv.length, "target": 34963]]
        var accessors: [[String: Any]] = [
            ["bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3", "min": [-0.5, -0.5, -0.5], "max": [0.5, 0.5, 0.5]],
            ["bufferView": 1, "componentType": 5123, "count": 36, "type": "SCALAR"],
        ]
        var attributes: [String: Any] = ["POSITION": 0]
        var json: [String: Any] = ["asset": ["version": "2.0", "generator": "Lift tests"], "scene": 0,
                                   "scenes": [["nodes": [0]]], "nodes": [["mesh": 0, "name": "Cube"]]]
        var primitive: [String: Any] = ["indices": 1]
        if textured {
            let tv = append(uv)
            views.append(["buffer": 0, "byteOffset": tv.offset, "byteLength": tv.length, "target": 34962])
            accessors.append(["bufferView": 2, "componentType": 5126, "count": 8, "type": "VEC2"])
            attributes["TEXCOORD_0"] = 2
            let png = try Self.png2x2()
            let imgv = append([UInt8](png))
            views.append(["buffer": 0, "byteOffset": imgv.offset, "byteLength": imgv.length])
            json["images"] = [["bufferView": 3, "mimeType": "image/png"]]
            json["textures"] = [["source": 0]]
            json["materials"] = [["name": "Checker", "pbrMetallicRoughness": ["baseColorTexture": ["index": 0], "metallicFactor": 0.0]]]
            primitive["material"] = 0
        }
        while bin.count % 4 != 0 { bin.append(0) }
        primitive["attributes"] = attributes
        json["meshes"] = [["primitives": [primitive]]]
        json["accessors"] = accessors
        json["bufferViews"] = views
        json["buffers"] = [["byteLength": bin.count]]
        var text = try JSONSerialization.data(withJSONObject: json, options: .sortedKeys)
        while text.count % 4 != 0 { text.append(0x20) }
        var glb = Data()
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { glb.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(12 + 8 + text.count + 8 + bin.count)
        u32(text.count); u32(0x4E4F_534A); glb.append(text)
        u32(bin.count); u32(0x004E_4942); glb.append(bin)
        let url = (try dir ?? tempDir()).appending(path: name)
        try glb.write(to: url)
        return url
    }

    private static func png2x2() throws -> Data {
        let ctx = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1); ctx.fill(CGRect(x: 1, y: 1, width: 1, height: 1))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
        return out as Data
    }
}
