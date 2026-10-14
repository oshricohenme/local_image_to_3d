import AVKit
import GLTFKit2
import SceneKit
import SwiftUI

/// Which viewer shows an output file (mockup Viewers.dc.html). Decided by the file's extension.
public enum ViewerKind: Equatable, Sendable {
    case mesh, image, video, audio, none

    public static func of(_ path: String) -> ViewerKind {
        switch URL(filePath: path).pathExtension.lowercased() {
        case "glb", "gltf", "obj", "usdz", "usd", "usdc": .mesh
        case "png", "jpg", "jpeg", "webp", "heic", "tiff": .image
        case "mp4", "mov", "m4v": .video
        case "wav", "mp3", "flac", "m4a", "aiff": .audio
        default: .none
        }
    }
}

struct ResultViewer: View {
    let path: String

    var body: some View {
        let url = URL(filePath: path)
        switch ViewerKind.of(path) {
        case .mesh: MeshView(url: url)
        case .image:
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                unavailable("Can't read this image")
            }
        case .video, .audio: VideoPlayer(player: AVPlayer(url: url))
        case .none: unavailable("No preview for .\(url.pathExtension) files")
        }
    }

    func unavailable(_ text: String) -> some View {
        ContentUnavailableView(text, systemImage: "eye.slash", description: Text("Use Reveal in Finder to open it in another app."))
    }
}

enum MeshMode: String, CaseIterable {
    case textured = "Textured", clay = "Clay", wireframe = "Wireframe", skeleton = "Skeleton"

    var debugOptions: SCNDebugOptions {
        switch self {
        case .wireframe: .renderAsWireframe
        case .skeleton: .showSkeletons
        default: []
        }
    }
}

/// 3D preview: glTF through GLTFKit2 into SceneKit; OBJ and USDZ through SceneKit (ModelIO).
/// Drag to orbit, scroll to zoom.
struct MeshView: View {
    let url: URL
    @State private var mode = MeshMode.textured
    @State private var loaded: (scene: SCNScene, animations: [GLTFSCNAnimation])?
    @State private var error: String?
    @State private var playing = false

    var body: some View {
        ZStack(alignment: .bottom) {
            if let loaded {
                SceneKitView(scene: loaded.scene, debugOptions: mode.debugOptions)
            } else if let error {
                ContentUnavailableView("Can't show this mesh", systemImage: "cube.transparent", description: Text(error))
            } else {
                ProgressView()
            }
            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(MeshMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let animations = loaded?.animations, !animations.isEmpty {
                    Toggle("Play animation", isOn: $playing).toggleStyle(.button)
                }
            }
            .padding(8)
        }
        .background(Color(white: 0.17))
        .task(id: "\(url.path)|\(mode == .clay)") { load(clay: mode == .clay) }
        .onChange(of: playing) { play(playing) }
    }

    // ponytail: parses on the main actor; move to a background task if big meshes stall the UI.
    func load(clay: Bool) {
        do {
            let scene: SCNScene
            var animations: [GLTFSCNAnimation] = []
            if ["glb", "gltf"].contains(url.pathExtension.lowercased()) {
                let source = GLTFSCNSceneSource(asset: try GLTFAsset(url: url, options: [:]))
                scene = source.defaultScene ?? SCNScene()
                animations = source.animations
                if clay {
                    for m in source.materials { Self.makeClay(m) }
                }
            } else {
                scene = try SCNScene(url: url)
                if clay {
                    scene.rootNode.enumerateHierarchy { node, _ in node.geometry?.materials.forEach(Self.makeClay) }
                }
            }
            loaded = (scene, animations)
            playing = false
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func makeClay(_ m: SCNMaterial) {
        m.diffuse.contents = NSColor(white: 0.75, alpha: 1)
        for p in [m.normal, m.emission, m.metalness, m.ambientOcclusion] { p.contents = nil }
        m.roughness.contents = 0.8
    }

    func play(_ on: Bool) {
        guard let loaded else { return }
        for (i, a) in loaded.animations.enumerated() {
            let key = "lift-\(i)"
            if on {
                loaded.scene.rootNode.addAnimationPlayer(a.animationPlayer, forKey: key)
                a.animationPlayer.play()
            } else {
                loaded.scene.rootNode.removeAnimation(forKey: key)
            }
        }
    }
}

struct SceneKitView: NSViewRepresentable {
    let scene: SCNScene
    let debugOptions: SCNDebugOptions

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = NSColor(white: 0.17, alpha: 1)
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        if view.scene !== scene { view.scene = scene }
        view.debugOptions = debugOptions
    }
}
