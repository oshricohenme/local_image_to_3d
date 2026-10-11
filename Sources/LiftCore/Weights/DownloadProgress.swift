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
