import CryptoKit
import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// File lists by `repo@revision`. Never touches the network. Unknown repos answer 404.
final class FakeMetadata: WeightsMetadata {
    private let answers = Mutex<[String: Result<RepoSnapshot, any Error>]>([:])
    /// Repo-wide failures (offline, an outage): every revision fails until the next `set`.
    private let down = Mutex<[String: any Error]>([:])

    /// A snapshot answer is also given for its commit, as the real API does.
    func set(_ repo: String, revision: String = "main", _ answer: Result<RepoSnapshot, WeightsMetadataError>) {
        down.withLock { $0[repo] = nil }
        answers.withLock {
            $0["\(repo)@\(revision)"] = answer.mapError { $0 as any Error }
            if case .success(let s) = answer { $0["\(repo)@\(s.commit)"] = .success(s) }
        }
    }

    func failAll(_ repo: String, _ error: WeightsMetadataError) {
        down.withLock { $0[repo] = error }
    }

    /// Any error, e.g. a `DecodingError` from a malformed API answer.
    func fail(_ repo: String, revision: String = "main", with error: any Error) {
        answers.withLock { $0["\(repo)@\(revision)"] = .failure(error) }
    }

    func snapshot(repo: String, revision: String) async throws -> RepoSnapshot {
        if let e = down.withLock({ $0[repo] }) { throw e }
        guard let a = answers.withLock({ $0["\(repo)@\(revision)"] }) else { throw WeightsMetadataError.http(status: 404, repo: repo) }
        return try a.get()
    }
}

func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Writes files the way `hf download` lays them out: `blobs/<sha>`, `snapshots/<commit>/<path>` symlinks and
/// `refs/<ref>` holding the commit. Returns the snapshot the API would report.
@discardableResult
func writeHFCache(hub: URL, repo: String, commit: String, files: [String: Data], lfs: Set<String>, ref: String? = "main") throws -> RepoSnapshot {
    let root = hub.appending(path: "models--" + repo.replacingOccurrences(of: "/", with: "--"))
    if let ref {
        try FileManager.default.createDirectory(at: root.appending(path: "refs"), withIntermediateDirectories: true)
        try commit.write(to: root.appending(path: "refs/\(ref)"), atomically: true, encoding: .utf8)
    }
    var remote: [RemoteFile] = []
    for (path, data) in files.sorted(by: { $0.key < $1.key }) {
        let sha = sha256Hex(data)
        let blob = root.appending(path: "blobs/\(sha)")
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: blob)
        let link = root.appending(path: "snapshots/\(commit)/\(path)")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: blob)
        remote.append(RemoteFile(path: path, size: data.count, sha256: lfs.contains(path) ? sha : nil))
    }
    return RepoSnapshot(repo: repo, revision: "main", commit: commit, files: remote)
}

@Suite struct WeightsTests {
    let commit = String(repeating: "c", count: 40)

    func recipe(_ weights: [Recipe.Weight] = [Recipe.Weight(repo: "org/model")]) throws -> Recipe {
        guard case .ok(var r) = RecipeLoad.read(directory: try writeRecipe(pixalYAML, id: "pixal3d", in: try Fixtures.tempDir())) else {
            throw LiftError.invalidState("fixture")
        }
        r.weights = weights
        return r
    }

    func setup() throws -> (FakeMetadata, URL, WeightsVerifier) {
        let meta = FakeMetadata(), hub = try Fixtures.tempDir()
        return (meta, hub, WeightsVerifier(metadata: meta, hub: hub, store: try Store()))
    }

    @Test func completeCacheVerifiesAndHashesAreCached() async throws {
        let (meta, hub, v) = try setup()
        let snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit,
                                    files: ["model.safetensors": Data(repeating: 7, count: 4096), "config.json": Data("{}".utf8)], lfs: ["model.safetensors"])
        meta.set("org/model", .success(snap))
        let first = try await v.verify(try recipe())
        #expect(first.state == .ok && first.problems.isEmpty && first.hashedFiles == 1)
        #expect(try await v.verify(try recipe()).hashedFiles == 0)  // size + mtime unchanged: cached hash
        #expect(await v.totalBytes(try recipe()) == 4098)
    }

    @Test func missingFileIsListed() async throws {
        let (meta, hub, v) = try setup()
        var snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit, files: ["a.bin": Data([1])], lfs: [])
        snap.files.append(RemoteFile(path: "sub/b.bin", size: 9, sha256: String(repeating: "0", count: 64)))
        meta.set("org/model", .success(snap))
        let r = try await v.verify(try recipe())
        #expect(r.state == .missing)
        #expect(r.problems == [WeightProblem(repo: "org/model", path: "sub/b.bin", issue: .missing)])
    }

    @Test func revisionNotDownloadedMeansAllMissing() async throws {
        let (meta, _, v) = try setup()
        meta.set("org/model", .success(RepoSnapshot(repo: "org/model", revision: "main", commit: commit, files: [RemoteFile(path: "a", size: 1), RemoteFile(path: "b", size: 2)])))
        #expect(try await v.verify(try recipe()).problems.map(\.path) == ["a", "b"])
    }

    @Test func wrongSizeAndWrongHashAreCorrupt() async throws {
        let (meta, hub, v) = try setup()
        var snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit,
                                    files: ["big.bin": Data(repeating: 1, count: 100), "w.safetensors": Data(repeating: 2, count: 50)], lfs: ["w.safetensors"])
        snap.files[0].size = 101
        snap.files[1].sha256 = String(repeating: "f", count: 64)
        meta.set("org/model", .success(snap))
        let r = try await v.verify(try recipe())
        #expect(r.state == .corrupt)
        #expect(r.problems.map(\.issue) == [.wrongSize, .wrongHash])
    }

    @Test func revisionsAreRespected() async throws {
        let (meta, hub, v) = try setup()
        var snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit, files: ["a": Data([1])], lfs: [], ref: "v2")
        snap.revision = "v2"
        meta.set("org/model", revision: "v2", .success(snap))
        #expect(try await v.verify(try recipe([Recipe.Weight(repo: "org/model", revision: "v2")])).state == .ok)
        #expect(try await v.verify(try recipe()).state == .unknown)  // main isn't known to the fake: 404
    }

    @Test func offlineFallsBackToTheLastGoodCheck() async throws {
        let (meta, hub, v) = try setup()
        let snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit, files: ["a.bin": Data([1, 2])], lfs: ["a.bin"])
        meta.set("org/model", .success(snap))
        #expect(try await v.verify(try recipe()).state == .ok)
        meta.failAll("org/model", .offline)
        let offline = try await v.verify(try recipe())
        #expect(offline.state == .ok && offline.metadataFrom != nil && offline.note?.contains("offline") == true)
    }

    /// I5: `main` moved upstream (say, a README push); the commit that was downloaded is what gets checked.
    @Test func verifiesTheDownloadedCommitNotTheMovingBranch() async throws {
        let (meta, hub, v) = try setup()
        let local = String(repeating: "a", count: 40), upstream = String(repeating: "b", count: 40)
        let snapA = try writeHFCache(hub: hub, repo: "org/model", commit: local, files: ["w.bin": Data([1, 2])], lfs: ["w.bin"])  // refs/main = A
        meta.set("org/model", revision: local, .success(snapA))
        meta.set("org/model", .success(RepoSnapshot(repo: "org/model", revision: "main", commit: upstream,
                                                    files: snapA.files + [RemoteFile(path: "README.md", size: 10)])))
        let r = try await v.verify(try recipe())
        #expect(r.state == .ok && r.problems.isEmpty)
        #expect(r.upstreamMoved == ["org/model: main is at bbbbbbb upstream; checked the downloaded aaaaaaa"])
    }

    /// I6: a Hugging Face outage (5xx) or rate limit (429) behaves like offline.
    @Test(arguments: [503, 429])
    func outageFallsBackToTheLastGoodCheck(status: Int) async throws {
        let (meta, hub, v) = try setup()
        let snap = try writeHFCache(hub: hub, repo: "org/model", commit: commit, files: ["a.bin": Data([1])], lfs: ["a.bin"])
        meta.failAll("org/model", .http(status: status, repo: "org/model"))
        let never = try await v.verify(try recipe())
        #expect(never.state == .unknown && never.note?.contains("\(status)") == true)
        meta.set("org/model", .success(snap))
        #expect(try await v.verify(try recipe()).state == .ok)
        meta.failAll("org/model", .http(status: status, repo: "org/model"))
        let r = try await v.verify(try recipe())
        #expect(r.state == .ok && r.metadataFrom != nil && r.note?.contains("\(status)") == true)
    }

    @Test func notFoundStaysUnknownEvenAfterAGoodCheck() async throws {
        let (meta, hub, v) = try setup()
        meta.set("org/model", .success(try writeHFCache(hub: hub, repo: "org/model", commit: commit, files: ["a.bin": Data([1])], lfs: [])))
        #expect(try await v.verify(try recipe()).state == .ok)
        meta.failAll("org/model", .http(status: 404, repo: "org/model"))
        #expect(try await v.verify(try recipe()).state == .unknown)
    }

    @Test func offlineWithoutAGoodCheckIsUnknown() async throws {
        let (meta, _, v) = try setup()
        meta.set("org/model", .failure(.offline))
        let r = try await v.verify(try recipe())
        #expect(r.state == .unknown && r.metadataFrom == nil)
    }

    @Test func gatedRefusalSaysSo() async throws {
        let (meta, _, v) = try setup()
        meta.set("org/model", .failure(.http(status: 401, repo: "org/model")))
        #expect(try await v.verify(try recipe()).note?.contains("gated") == true)
    }

    @Test func noWeightsIsOK() async throws {
        let (_, _, v) = try setup()
        #expect(try await v.verify(try recipe([])).state == .ok)
    }
}
