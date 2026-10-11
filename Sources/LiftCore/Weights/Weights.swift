import CryptoKit
import Foundation
import GRDB

/// One file of a Hugging Face repo at a commit. `sha256` is set for LFS files.
public struct RemoteFile: Codable, Sendable, Equatable {
    public var path: String
    public var size: Int
    public var sha256: String?

    public init(path: String, size: Int, sha256: String? = nil) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// A repo's file list at a revision, as the Hugging Face API reports it.
public struct RepoSnapshot: Codable, Sendable, Equatable {
    public var repo: String
    public var revision: String
    /// The commit the revision resolves to; the local cache keeps files under `snapshots/<commit>/`.
    public var commit: String
    public var files: [RemoteFile]

    public init(repo: String, revision: String, commit: String, files: [RemoteFile]) {
        self.repo = repo
        self.revision = revision
        self.commit = commit
        self.files = files
    }
}

public enum WeightsMetadataError: Error, Sendable, Equatable {
    /// No network (or Hugging Face unreachable): verification may fall back to the last good check.
    case offline
    case http(status: Int, repo: String)
}

/// Where file lists come from. Tests inject a fake; nothing in the test suite talks to Hugging Face.
public protocol WeightsMetadata: Sendable {
    func snapshot(repo: String, revision: String) async throws -> RepoSnapshot
}

/// `GET /api/models/<repo>/revision/<revision>?blobs=true`: commit sha, file sizes and LFS SHA-256.
public struct HFHubAPI: WeightsMetadata {
    let endpoint: URL
    let token: @Sendable () -> String?

    public init(endpoint: URL = URL(string: "https://huggingface.co")!, token: @escaping @Sendable () -> String?) {
        self.endpoint = endpoint
        self.token = token
    }

    public func snapshot(repo: String, revision: String) async throws -> RepoSnapshot {
        let rev = revision.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? revision
        var request = URLRequest(url: URL(string: "\(endpoint.absoluteString)/api/models/\(repo)/revision/\(rev)?blobs=true")!)
        if let token = token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch is URLError { throw WeightsMetadataError.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw WeightsMetadataError.http(status: status, repo: repo) }
        struct Info: Decodable {
            struct Sibling: Decodable {
                struct LFS: Decodable { var sha256: String; var size: Int }
                var rfilename: String
                var size: Int?
                var lfs: LFS?
            }
            var sha: String
            var siblings: [Sibling]
        }
        let info = try JSONDecoder().decode(Info.self, from: data)
        return RepoSnapshot(repo: repo, revision: revision, commit: info.sha, files: info.siblings.map {
            RemoteFile(path: $0.rfilename, size: $0.lfs?.size ?? $0.size ?? 0, sha256: $0.lfs?.sha256)
        })
    }

    /// The shared cache `hf download` writes to: `$HF_HUB_CACHE`, `$HF_HOME/hub`, `$XDG_CACHE_HOME/huggingface/hub`
    /// or `~/.cache/huggingface/hub`.
    public static var defaultCache: URL {
        let env = ProcessInfo.processInfo.environment
        if let v = env["HF_HUB_CACHE"] { return URL(filePath: v) }
        if let v = env["HF_HOME"] { return URL(filePath: v).appending(path: "hub") }
        if let v = env["XDG_CACHE_HOME"] { return URL(filePath: v).appending(path: "huggingface/hub") }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub")
    }
}

public struct WeightProblem: Codable, Sendable, Equatable {
    public enum Issue: String, Codable, Sendable { case missing, wrongSize = "wrong_size", wrongHash = "wrong_hash" }
    public var repo: String
    public var path: String
    public var issue: Issue
    public var detail: String?
}

public struct WeightsReport: Codable, Sendable, Equatable {
    /// `unknown`: couldn't be checked (offline and never verified, or Hugging Face refused).
    public enum State: String, Codable, Sendable { case ok, missing, corrupt, unknown }
    public var state: State
    public var problems: [WeightProblem]
    public var checkedAt: Date
    /// Files hashed in this run; cached hashes are reused while size and mtime are unchanged.
    public var hashedFiles: Int
    /// Set when Lift was offline and checked against the file lists of the last good check, made at this time.
    public var metadataFrom: Date?
    public var note: String?
}

/// A cached SHA-256 of one weight file, valid while its size and mtime are unchanged.
public struct WeightHashRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "weightHash"
    /// Resolved path of the blob in the Hugging Face cache.
    public var path: String
    public var size: Int
    public var mtime: Double
    public var sha256: String
}

/// The last successful verification of a recipe's weights, kept so an offline check can reuse its file lists.
public struct WeightCheckRecord: Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "weightCheck"
    public var recipe: String
    public var at: Date
    public var snapshots: [RepoSnapshot]
}

/// Checks a recipe's weights in the local Hugging Face cache (spec §6): every file present at the
/// revision's commit, sizes equal, LFS files hashed. Read-only on the cache.
public struct WeightsVerifier: Sendable {
    let metadata: any WeightsMetadata
    let hub: URL
    let store: Store

    public init(metadata: any WeightsMetadata, hub: URL, store: Store) {
        self.metadata = metadata
        self.hub = hub
        self.store = store
    }

    /// `models--org--name/snapshots/<commit>` for a repo.
    public func snapshotDir(repo: String, commit: String) -> URL {
        hub.appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--")).appending(path: "snapshots/\(commit)")
    }

    /// Total bytes of the recipe's weights, or nil when the file lists can't be fetched.
    public func totalBytes(_ recipe: Recipe) async -> Int? {
        var total = 0
        for w in recipe.weights {
            guard let s = try? await metadata.snapshot(repo: w.repo, revision: w.revision) else { return nil }
            total += s.files.reduce(0) { $0 + $1.size }
        }
        return total
    }

    public func verify(_ recipe: Recipe) async throws -> WeightsReport {
        let now = Date()
        var report = WeightsReport(state: .ok, problems: [], checkedAt: now, hashedFiles: 0)
        guard !recipe.weights.isEmpty else { return report }
        var snapshots: [RepoSnapshot] = []
        do {
            for w in recipe.weights { snapshots.append(try await metadata.snapshot(repo: w.repo, revision: w.revision)) }
        } catch WeightsMetadataError.offline {
            let wanted = Set(recipe.weights.map { "\($0.repo)@\($0.revision)" })
            guard let last = try await store.db.read({ try WeightCheckRecord.fetchOne($0, key: recipe.id) }),
                  Set(last.snapshots.map { "\($0.repo)@\($0.revision)" }) == wanted else {
                report.state = .unknown
                report.note = "offline, and these weights have never been verified"
                return report
            }
            snapshots = last.snapshots
            report.metadataFrom = last.at
            report.note = "offline: checked against the file lists from the last good check"
        } catch WeightsMetadataError.http(let status, let repo) {
            report.state = .unknown
            report.note = "Hugging Face answered \(status) for \(repo)" + ([401, 403].contains(status) ? " (gated: needs a token with access)" : "")
            return report
        }

        for s in snapshots {
            let dir = snapshotDir(repo: s.repo, commit: s.commit)
            for f in s.files {
                let url = dir.appending(path: f.path).resolvingSymlinksInPath()
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                    report.problems.append(WeightProblem(repo: s.repo, path: f.path, issue: .missing))
                    continue
                }
                let size = (attrs[.size] as? Int) ?? -1
                guard size == f.size else {
                    report.problems.append(WeightProblem(repo: s.repo, path: f.path, issue: .wrongSize, detail: "\(size) bytes, expected \(f.size)"))
                    continue
                }
                guard let expected = f.sha256 else { continue }
                let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let cached = try await store.db.read { try WeightHashRecord.fetchOne($0, key: url.path) }
                var sha = cached.flatMap { $0.size == size && $0.mtime == mtime ? $0.sha256 : nil }
                if sha == nil {
                    let computed = try Self.sha256(url)
                    report.hashedFiles += 1
                    try await store.db.write { try WeightHashRecord(path: url.path, size: size, mtime: mtime, sha256: computed).save($0) }
                    sha = computed
                }
                if sha != expected {
                    report.problems.append(WeightProblem(repo: s.repo, path: f.path, issue: .wrongHash, detail: "sha256 \(sha!), expected \(expected)"))
                }
            }
        }
        if report.problems.contains(where: { $0.issue == .missing }) { report.state = .missing }
        else if !report.problems.isEmpty { report.state = .corrupt }
        if report.state == .ok && report.metadataFrom == nil {
            let record = WeightCheckRecord(recipe: recipe.id, at: now, snapshots: snapshots)
            try await store.db.write { try record.save($0) }
        }
        return report
    }

    /// Streams the file through SHA-256 in 8 MB chunks.
    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hash = SHA256()
        while let chunk = try h.read(upToCount: 8 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
