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

extension RepoSnapshot {
    /// Just these files (a recipe's `weights[].files`); nil keeps the whole repo.
    func only(_ paths: [String]?) -> RepoSnapshot {
        guard let paths else { return self }
        var s = self
        s.files = files.filter { paths.contains($0.path) }
        return s
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
    /// Informational, never blocking: a branch/tag that has moved upstream past the downloaded commit.
    public var upstreamMoved: [String] = []
}

extension WeightsReport {
    /// The check itself threw (a malformed API answer, a read or database error).
    static func failedCheck(_ error: any Error) -> WeightsReport {
        WeightsReport(state: .unknown, problems: [], checkedAt: Date(), hashedFiles: 0, note: "the check failed: \(error)")
    }
}

extension WeightsVerifier {
    /// `verify`, with a thrown error turned into an `unknown` report.
    func report(_ recipe: Recipe) async -> WeightsReport {
        do { return try await verify(recipe) } catch { return .failedCheck(error) }
    }
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

    func repoDir(_ repo: String) -> URL { hub.appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--")) }

    /// `models--org--name/snapshots/<commit>` for a repo.
    public func snapshotDir(repo: String, commit: String) -> URL {
        repoDir(repo).appending(path: "snapshots/\(commit)")
    }

    /// The commit the local cache has for a revision: the revision itself if it's a sha, else `refs/<revision>`.
    func localCommit(repo: String, revision: String) -> String? {
        if revision.range(of: #"^[0-9a-f]{40}$"#, options: .regularExpression) != nil { return revision }
        let ref = (try? String(contentsOf: repoDir(repo).appending(path: "refs/\(revision)"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ref?.isEmpty == false ? ref : nil
    }

    /// The file list to check against: that of the locally downloaded commit when there is one (a branch
    /// moving upstream doesn't make local weights "missing"), else that of the revision as the API resolves it.
    func snapshot(for w: Recipe.Weight, report: inout WeightsReport) async throws -> RepoSnapshot {
        guard let local = localCommit(repo: w.repo, revision: w.revision) else {
            return try await metadata.snapshot(repo: w.repo, revision: w.revision)
        }
        var s = try await metadata.snapshot(repo: w.repo, revision: local)
        s.revision = w.revision
        if local != w.revision, let head = try? await metadata.snapshot(repo: w.repo, revision: w.revision), head.commit != local {
            report.upstreamMoved.append("\(w.repo): \(w.revision) is at \(head.commit.prefix(7)) upstream; checked the downloaded \(local.prefix(7))")
        }
        return s
    }

    /// Total bytes of the recipe's weights, or nil when the file lists can't be fetched.
    public func totalBytes(_ recipe: Recipe) async -> Int? {
        var total = 0
        for w in recipe.weights {
            guard let s = try? await metadata.snapshot(repo: w.repo, revision: w.revision).only(w.files) else { return nil }
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
            for w in recipe.weights {
                let s = try await snapshot(for: w, report: &report)
                for path in w.files ?? [] where !s.files.contains(where: { $0.path == path }) {
                    report.problems.append(WeightProblem(repo: w.repo, path: path, issue: .missing, detail: "not in \(w.repo)@\(w.revision)"))
                }
                snapshots.append(s.only(w.files))
            }
        } catch let error as WeightsMetadataError {
            // Offline, an outage (5xx) or a rate limit (429): fall back to the last good check's file lists.
            // A refusal (401/403/404) is an answer, not an outage: unknown.
            let why: String
            switch error {
            case .offline: why = "offline"
            case .http(let status, _) where status == 429 || status >= 500: why = "Hugging Face unavailable (HTTP \(status))"
            case .http(let status, let repo):
                report.state = .unknown
                report.note = "Hugging Face answered \(status) for \(repo)" + ([401, 403].contains(status) ? " (gated: needs a token with access)" : "")
                return report
            }
            let wanted = Set(recipe.weights.map { "\($0.repo)@\($0.revision)" })
            guard let last = try await store.db.read({ try WeightCheckRecord.fetchOne($0, key: recipe.id) }),
                  Set(last.snapshots.map { "\($0.repo)@\($0.revision)" }) == wanted else {
                report.state = .unknown
                report.note = "\(why), and these weights have never been verified"
                return report
            }
            snapshots = last.snapshots
            report.metadataFrom = last.at
            report.note = "\(why): checked against the file lists from the last good check"
        }

        for s in snapshots {
            let dir = snapshotDir(repo: s.repo, commit: s.commit)
            for f in s.files {
                let link = dir.appending(path: f.path)
                let url = link.resolvingSymlinksInPath()
                // fileExists follows the link: a snapshot link whose blob is gone is missing, not corrupt (M2).
                guard FileManager.default.fileExists(atPath: link.path), let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
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
