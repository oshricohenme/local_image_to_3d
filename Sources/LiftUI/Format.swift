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
        case .installing(let phase): installPhase(phase) + "…"
        case .installed: "Installed"
        case .updateAvailable: "Update available"
        case .installFailed: "Install failed"
        case .unsupported: "Unsupported"
        case .weightsMissing: "Weights missing"
        case .weightsCorrupt: "Weights corrupt"
        }
    }

    /// An install's phase (LiftCore's `installing {phase}`) in plain words.
    public static func installPhase(_ phase: String) -> String {
        switch phase {
        case "getting the code": "Getting the code"
        case "setting up python": "Setting up Python"
        case "checking the install": "Checking the install"
        case "downloading weights": "Downloading the model"
        case "verifying weights": "Checking the files"
        case "cancelling": "Stopping"
        default: phase.prefix(1).uppercased() + phase.dropFirst()
        }
    }

    /// "Downloading the model — 3.2 of 20.1 GB · about 5 min left"; the bytes only with a total, the time only
    /// once there's a rate to go by.
    public static func installLine(_ phase: String, progress: InstallProgress?, secondsLeft: Int?) -> String {
        var line = installPhase(phase)
        guard let p = progress else { return line }
        let gb = { (n: Int) in (Double(n) / 1e9).formatted(.number.precision(.fractionLength(1))) }
        line += " — \(gb(p.downloadedBytes)) of \(gb(p.totalBytes)) GB"
        if let s = secondsLeft { line += " · " + (s < 60 ? "less than a minute left" : "about \((s + 59) / 60) min left") }
        return line
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

extension Format {
    static func export(_ format: ExportFormat) -> String {
        switch format {
        case .glb: "GLB"
        case .usdz: "USDZ"
        case .obj: "OBJ"
        case .fbx: "FBX"
        }
    }

    static func exportHelp(_ format: ExportFormat) -> String {
        switch format {
        case .glb: "Works in almost every 3D app and on the web."
        case .usdz: "Opens in Quick Look, Reality Composer and on iPhone and iPad."
        case .obj: "For older 3D apps; saved as a folder with its textures."
        case .fbx: "For game engines and animation tools. Needs UniRig installed (it brings Blender)."
        }
    }
}

/// A download's recent rate, from the byte counts sampled each refresh: the time left is given only once the
/// samples span 10 s, and follows the last 30 s, so a change of speed shows quickly.
public struct RateEstimate: Sendable {
    var samples: [(at: Date, bytes: Int)] = []

    public init() {}

    public mutating func add(_ bytes: Int, at date: Date) {
        samples.append((date, bytes))
        samples.removeAll { date.timeIntervalSince($0.at) > 30 }
    }

    public func secondsLeft(total: Int) -> Int? {
        guard let first = samples.first, let last = samples.last else { return nil }
        let span = last.at.timeIntervalSince(first.at)
        guard span >= 10, last.bytes > first.bytes else { return nil }
        let rate = Double(last.bytes - first.bytes) / span
        return Int((Double(max(0, total - last.bytes)) / rate).rounded(.up))
    }
}
