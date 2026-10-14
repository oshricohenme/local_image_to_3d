import Foundation

/// How far a weights download has got: bytes in the Hugging Face cache out of the recipe's total (spec §6).
public struct InstallProgress: Codable, Sendable, Equatable {
    public var downloadedBytes: Int
    public var totalBytes: Int

    public init(downloadedBytes: Int, totalBytes: Int) {
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
    }
}

public enum WeightsProgress {
    /// Bytes of these repos already in the cache: every blob, finished or still `.incomplete` (what `hf download`
    /// appends to). Blobs from earlier downloads count too, which is right: `hf download` skips them.
    public static func downloadedBytes(hub: URL, repos: [String]) -> Int {
        let fm = FileManager.default
        return Set(repos).reduce(0) { total, repo in
            let blobs = hub.appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--") + "/blobs")
            let files = (try? fm.contentsOfDirectory(at: blobs, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return total + files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
    }
}

/// What `hf download` itself reports: its tqdm byte bars, one per file ("model.safetensors:  42%|████▏ |
/// 1.68G/4.00G [00:30<00:41, 56.2MB/s]"), each update arriving as a line (tqdm redraws with `\r`). With hf_xet a
/// file's blob may appear only once it's complete, so this count moves when the cache doesn't. Count bars
/// ("Fetching 4 files … it/s") are skipped.
public struct HFProgress: Sendable {
    var files: [String: Int] = [:]

    public init() {}

    /// Bytes downloaded so far across every file bar seen.
    public var bytes: Int { files.values.reduce(0, +) }

    static let bar = try! NSRegularExpression(
        pattern: #"^\s*(.*?):?\s*\d+%\|.*?\|\s*([\d.]+)\s*([kMGTP]?)i?B?/([\d.]+)\s*([kMGTP]?)i?B?\s*\[[^\]]*B/s"#)

    public mutating func read(_ line: String, repo: String) {
        guard let m = Self.bar.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return }
        func group(_ i: Int) -> String { Range(m.range(at: i), in: line).map { String(line[$0]) } ?? "" }
        guard let done = Double(group(2)) else { return }
        let scale: [String: Double] = ["": 1, "k": 1e3, "M": 1e6, "G": 1e9, "T": 1e12, "P": 1e15]
        files[repo + "/" + group(1)] = Int((done * (scale[group(3)] ?? 1)).rounded())
    }
}
