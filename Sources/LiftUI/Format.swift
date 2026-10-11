import Foundation
import LiftCore

/// Display text for LiftCore values. Facts only, no advice (spec principle 2).
public enum Format {
    public static func bytes(_ n: Int) -> String {
        n.formatted(.byteCount(style: .memory))
    }

    public static func gb(_ n: Int) -> String {
        (Double(n) / 1_000_000_000).formatted(.number.precision(.fractionLength(1))) + " GB"
    }

    public static func waitReason(_ r: WaitReason?) -> String {
        switch r {
        case nil: "Queued"
        case .noFreeSlot: "Waiting for a free slot"
        case .memory(let needed, let free): "Needs \(gb(needed)), \(gb(free)) free"
        case .modelInstalling: "Model is installing"
        case .modelNotInstalled: "Model not installed"
        case .modelUnsupported: "Model unsupported on this Mac"
        case .weightsUnverified: "Weights not verified"
        case .queuePaused: "Queue paused"
        }
    }

    public static func state(_ s: JobState) -> String {
        s.rawValue.prefix(1).uppercased() + s.rawValue.dropFirst()
    }

    public static func status(_ s: ModelStatus) -> String {
        switch s {
        case .notInstalled: "Not installed"
        case .installing(let phase): phase.prefix(1).uppercased() + phase.dropFirst() + "…"
        case .installed: "Installed"
        case .updateAvailable: "Update available"
        case .installFailed: "Install failed"
        case .unsupported: "Unsupported"
        case .weightsMissing: "Weights missing"
        case .weightsCorrupt: "Weights corrupt"
        }
    }

    /// Names used in task chips: "Image → 3D", "Mesh → Rigged".
    public static func io(_ t: IOType, asOutput: Bool = false) -> String {
        switch t {
        case .text: "Text"
        case .image: "Image"
        case .imageSet: "Multi-view"
        case .mesh: asOutput ? "3D" : "Mesh"
        case .riggedMesh: "Rigged"
        case .video: "Video"
        case .audio: "Audio"
        }
    }

    public static func elapsed(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "" }
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    public static func source(_ s: JobSource) -> String {
        switch s {
        case .ui: "App"
        case .http: "HTTP"
        case .mcp: "MCP"
        }
    }

    public static func error(_ e: any Error) -> String {
        (e as? LiftError)?.description ?? e.localizedDescription
    }
}

/// File extensions a task input of this type accepts in the drop zone and the open panel.
public extension IOType {
    var fileExtensions: [String] {
        switch self {
        case .text: []
        case .image: ["png", "jpg", "jpeg", "webp"]
        case .imageSet: []  // a folder
        case .mesh, .riggedMesh: ["glb", "gltf", "fbx", "obj"]
        case .video: ["mp4", "mov"]
        case .audio: ["wav", "mp3", "flac", "m4a"]
        }
    }
}
