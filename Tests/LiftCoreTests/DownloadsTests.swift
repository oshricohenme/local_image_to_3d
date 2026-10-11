import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// The download queue behind every weights download (spec §6): persisted, one at a time by default, pause /
/// resume / cancel / retry, resumed at launch, network errors retried with backoff, gated access failing at once.
/// `hf download` is a FakeRunner rule and the cache a temp folder: nothing is downloaded.
@Suite struct DownloadsTests {
    static let commit = String(repeating: "c", count: 40)

    /// The Test Cube plus `w1`…`wN`, copies of it that each need one Hugging Face repo (`org/w1`…).
    static func bundle(_ n: Int) throws -> URL {
        let b = try cubeOnlyBundle()
        let cube = try String(contentsOf: Fixtures.devRecipes.appending(path: "test-cube/recipe.yaml"), encoding: .utf8)
        for i in 1...n {
            _ = try writeRecipe(cube.replacingOccurrences(of: "id: test-cube", with: "id: w\(i)")
                .replacingOccurrences(of: "resources:", with: "weights:\n  - { repo: org/w\(i) }\nresources:"), id: "w\(i)", in: b)
        }
        return b
    }

    /// The backoff waits a download asked for.
    final class Sleeps: Sendable {
        let waits = Mutex<[Duration]>([])
        var all: [Duration] { waits.withLock { $0 } }
    }

    struct Rig {
        let lift: Lift
        let runner: FakeRunner
        let hub: URL
        let workdir: URL
        let sleeps: Sleeps
    }

    /// `n` models installed (a fake install with an `hf` in each venv), no download started yet.
    static func rig(_ n: Int = 1, runner: FakeRunner = FakeRunner(), workdir: URL? = nil, hub: URL? = nil) async throws -> Rig {
        let workdir = try workdir ?? Fixtures.tempDir(), hub = try hub ?? Fixtures.tempDir()
        let meta = FakeMetadata()
        for i in 1...n {
            meta.set("org/w\(i)", .success(RepoSnapshot(repo: "org/w\(i)", revision: "main", commit: commit, files: [RemoteFile(path: "w.bin", size: 1000)])))
            let bin = workdir.appending(path: "models/w\(i)/venv/bin")
            runner.on("venv --python 3.11 \(workdir.appending(path: "models/w\(i)/venv").path)", effect: {
                try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                try? "#!/bin/sh\n".write(to: bin.appending(path: "hf"), atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "hf").path)
            })
        }
        let sleeps = Sleeps()
        let lift = try await Fixtures.lift(runner, workdir: workdir, searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path],
                                           bundle: try bundle(n), metadata: meta, hub: hub, sleep: { d in sleeps.waits.withLock { $0.append(d) } })
        for i in 1...n where try await lift.modelsGet("w\(i)").status == .notInstalled {
            _ = try await lift.modelsInstall("w\(i)", confirm: true, wait: true, downloadWeights: false)
        }
        return Rig(lift: lift, runner: runner, hub: hub, workdir: workdir, sleeps: sleeps)
    }

    func states(_ lift: Lift) async throws -> [String: Download.State] {
        Dictionary(uniqueKeysWithValues: try await lift.downloadsList().map { ($0.model, $0.state) })
    }

    @Test func aDownloadIsARecordThatRunsThenVerifiesTheWeights() async throws {
        let runner = FakeRunner()
        let hub = try Fixtures.tempDir()
        runner.on("download org/w1", effect: {
            _ = try? writeHFCache(hub: hub, repo: "org/w1", commit: Self.commit, files: ["w.bin": Data(count: 1000)], lfs: [])
        })
        let rig = try await Self.rig(runner: runner, hub: hub)
        _ = try await rig.lift.modelsDownloadWeights("w1", confirm: true, wait: true)
        let d = try #require(try await rig.lift.downloadsList().first)
        #expect(d.model == "w1" && d.weights.map(\.repo) == ["org/w1"] && d.state == .done && d.totalBytes == 1000)
        #expect(d.startedAt != nil && d.finishedAt != nil && d.reason == nil)
        #expect(try await rig.lift.modelsGet("w1").status == .installed(commit: nil))  // verified: the install carried on
        #expect(try await rig.lift.modelsGet("w1").download == nil)  // a finished download no longer shows on the model
        await rig.lift.close()
        let again = try await Self.rig(runner: runner, workdir: rig.workdir, hub: hub)
        #expect(try await again.lift.downloadsList().map(\.id) == [d.id])  // kept in the database
    }

    @Test func oneAtATimeByDefaultAndMaxDownloadsAllowsMore() async throws {
        let runner = FakeRunner()
        runner.on("hf download", delay: .seconds(30))
        let rig = try await Self.rig(3, runner: runner)
        for i in 1...3 { _ = try await rig.lift.modelsDownloadWeights("w\(i)", confirm: true) }
        #expect(try await states(rig.lift) == ["w1": .downloading, "w2": .queued, "w3": .queued])
        #expect(try await rig.lift.modelsGet("w2").status == .installing(phase: "waiting to download"))
        _ = try await rig.lift.settingsSet("max_downloads", .int(2))
        #expect(try await eventually { try await states(rig.lift) == ["w1": .downloading, "w2": .downloading, "w3": .queued] })
        await #expect(throws: LiftError.self) { try await rig.lift.settingsSet("max_downloads", .int(4)) }
        await #expect(throws: LiftError.self) { try await rig.lift.settingsSet("max_downloads", .int(0)) }
        await rig.lift.close()
    }

    @Test func downloadNowMovesAQueuedDownloadToTheFront() async throws {
        let runner = FakeRunner()
        runner.on("hf download", delay: .seconds(30))
        let rig = try await Self.rig(3, runner: runner)
        for i in 1...3 { _ = try await rig.lift.modelsDownloadWeights("w\(i)", confirm: true) }
        let w3 = try #require(try await rig.lift.downloadsList().first { $0.model == "w3" })
        _ = try await rig.lift.downloadsReorder(w3.id, position: 0)
        #expect(try await rig.lift.downloadsList().filter { $0.state == .queued }.map(\.model) == ["w3", "w2"])
        let w1 = try #require(try await rig.lift.downloadsList().first { $0.model == "w1" })
        _ = try await rig.lift.downloadsPause(w1.id)
        #expect(try await eventually { try await states(rig.lift)["w3"] == .downloading })  // the front of the queue goes next
        #expect(try await states(rig.lift)["w2"] == .queued)
        await rig.lift.close()
    }

    @Test func pauseResumeCancelAndRetry() async throws {
        let runner = FakeRunner()
        let hub = try Fixtures.tempDir()
        let partial = hub.appending(path: "models--org--w1/blobs/abc.incomplete")
        runner.on("hf download", delay: .seconds(30), effect: {
            try? FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(count: 400).write(to: partial)
        })
        let rig = try await Self.rig(runner: runner, hub: hub)
        let id = try #require(try await rig.lift.modelsDownloadWeights("w1", confirm: true).value?.download?.id)
        #expect(try await eventually { try await rig.lift.downloadsList().first?.downloadedBytes == 400 })
        var d = try await rig.lift.downloadsPause(id)
        #expect(d.state == .paused && FileManager.default.fileExists(atPath: partial.path))
        #expect(try await rig.lift.modelsGet("w1").status == .installing(phase: "download paused"))
        await #expect(throws: LiftError.self) { try await rig.lift.downloadsRetry(id) }  // only a failed or stopped one
        d = try await rig.lift.downloadsResume(id)
        #expect(try await eventually { try await rig.lift.downloadsList().first?.state == .downloading })
        #expect(try await eventually { runner.displays.filter { $0.contains("hf download") }.count == 2 })  // started again: hf picks up from its .incomplete files
        #expect(try await rig.lift.downloadsCancel(id).impact?.contains("stays") == true)  // asks first
        #expect(try await rig.lift.downloadsList().first?.state == .downloading)
        d = try #require(try await rig.lift.downloadsCancel(id, confirm: true).value)
        #expect(d.state == .cancelled && FileManager.default.fileExists(atPath: partial.path))  // never deletes what it downloaded
        await #expect(throws: LiftError.self) { try await rig.lift.downloadsPause(id) }
        d = try await rig.lift.downloadsRetry(id)
        #expect(try await eventually { try await rig.lift.downloadsList().first?.state == .downloading })
        _ = try await rig.lift.downloadsCancel(id, confirm: true)
        #expect(FileManager.default.fileExists(atPath: partial.path))
        await rig.lift.close()
    }

    @Test func aDownloadCutShortByAQuitResumesAtLaunch() async throws {
        let slow = FakeRunner()
        slow.on("hf download", delay: .seconds(30))
        let rig = try await Self.rig(runner: slow)
        _ = try await rig.lift.modelsDownloadWeights("w1", confirm: true)
        #expect(try await eventually { try await rig.lift.downloadsList().first?.state == .downloading })
        await rig.lift.close()  // quit mid-download

        let fast = FakeRunner()
        fast.on("hf download", delay: .milliseconds(300))
        let again = try await Self.rig(runner: fast, workdir: rig.workdir, hub: rig.hub)
        let resumed = try #require(try await again.lift.downloadsList().first)
        #expect(resumed.resumed && resumed.state != .done)  // "Resuming"
        #expect(try await eventually { try await again.lift.downloadsList().first?.state == .done })
        await again.lift.close()
    }

    @Test func networkErrorsAreRetriedWithBackoffThenFail() async throws {
        let lost = ["requests.exceptions.ConnectionError: HTTPSConnectionPool(host='huggingface.co'): Max retries exceeded"]
        let flaky = FakeRunner()
        flaky.on("hf download", code: 1, lines: lost, times: 2)
        let rig = try await Self.rig(runner: flaky)
        _ = try await rig.lift.modelsDownloadWeights("w1", confirm: true, wait: true)
        #expect(try await rig.lift.downloadsList().first?.state == .done)
        #expect(rig.sleeps.all == [.seconds(5), .seconds(20)])

        let down = FakeRunner()
        down.on("hf download", code: 1, lines: lost, times: 4)
        let other = try await Self.rig(runner: down)
        _ = try await other.lift.modelsDownloadWeights("w1", confirm: true, wait: true)
        let failed = try #require(try await other.lift.downloadsList().first)
        #expect(failed.state == .failed && failed.attempts == 4 && other.sleeps.all == [.seconds(5), .seconds(20), .seconds(60)])
        #expect(failed.reason?.contains("couldn't reach Hugging Face") == true)
        _ = try await other.lift.downloadsRetry(failed.id)  // the network is back
        #expect(try await eventually { try await other.lift.downloadsList().first?.state == .done })
    }

    @Test func gatedAccessFailsAtOnceWithTheTermsToAccept() async throws {
        let runner = FakeRunner()
        runner.on("hf download", code: 1, lines: ["huggingface_hub.errors.GatedRepoError: 403 Client Error. Cannot access gated repo for url https://huggingface.co/org/w1"])
        let rig = try await Self.rig(runner: runner)
        _ = try await rig.lift.modelsDownloadWeights("w1", confirm: true, wait: true)
        let d = try #require(try await rig.lift.downloadsList().first)
        #expect(d.state == .failed && d.attempts == 1 && rig.sleeps.all.isEmpty)
        #expect(d.reason == "Accept org/w1's terms on Hugging Face" && d.link == URL(string: "https://huggingface.co/org/w1"))
        #expect(try await rig.lift.modelsGet("w1").download?.state == .failed)  // the card shows it, with Retry
    }

    @Test func hfDownloadRunsInItsOwnProcessGroup() async throws {
        let runner = FakeRunner()
        let rig = try await Self.rig(runner: runner)
        _ = try await rig.lift.modelsDownloadWeights("w1", confirm: true, wait: true)
        #expect(runner.commands.first { $0.display.contains("hf download") }?.ownProcessGroup == true)  // so Pause kills all of it
    }
}
