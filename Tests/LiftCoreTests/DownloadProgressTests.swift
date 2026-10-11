import Foundation
import Synchronization
import Testing
@testable import LiftCore

/// Install progress (spec §1: honest progress): the phase in plain steps, and real bytes while weights download.
@Suite struct DownloadProgressTests {
    let commit = String(repeating: "c", count: 40)

    @Test func downloadedBytesCountFinishedAndIncompleteBlobsOfTheseReposOnly() throws {
        let hub = try Fixtures.tempDir()
        let blobs = hub.appending(path: "models--org--weights/blobs")
        let other = hub.appending(path: "models--org--other/blobs")
        for dir in [blobs, other] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        #expect(WeightsProgress.downloadedBytes(hub: hub, repos: ["org/weights", "org/absent"]) == 0)
        try Data(count: 100).write(to: blobs.appending(path: "aaa"))
        try Data(count: 30).write(to: blobs.appending(path: "bbb.incomplete"))
        try Data(count: 999).write(to: other.appending(path: "ccc"))
        #expect(WeightsProgress.downloadedBytes(hub: hub, repos: ["org/weights"]) == 130)
        let growing = try FileHandle(forWritingTo: blobs.appending(path: "bbb.incomplete"))  // hf download appending
        try growing.seekToEnd()
        try growing.write(contentsOf: Data(count: 20))
        try growing.close()
        #expect(WeightsProgress.downloadedBytes(hub: hub, repos: ["org/weights"]) == 150)
        #expect(WeightsProgress.downloadedBytes(hub: hub, repos: ["org/weights", "org/other"]) == 1149)
    }

    /// `weighted` with a fake `hf` in its venv; `download` runs while `hf download` is "running".
    func lift(_ runner: FakeRunner, hub: URL, size: Int = 2000, download: @escaping @Sendable () -> Void) async throws -> Lift {
        let workdir = try Fixtures.tempDir()
        let meta = FakeMetadata()
        meta.set("org/weights", .success(RepoSnapshot(repo: "org/weights", revision: "main", commit: commit, files: [RemoteFile(path: "w.bin", size: size)])))
        let bin = workdir.appending(path: "models/weighted/venv/bin")
        runner.on("venv --python", effect: {
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try? "#!/bin/sh\n".write(to: bin.appending(path: "hf"), atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appending(path: "hf").path)
        })
        runner.on("download org/weights", effect: download)
        return try await Fixtures.lift(runner, workdir: workdir, searchDirs: [try Fixtures.fakeBin(["git", "uv"]).path],
                                       bundle: try weightedBundle(), metadata: meta, hub: hub)
    }

    @Test func aDownloadReportsRealBytesThenClearsThem() async throws {
        let hub = try Fixtures.tempDir()
        let blobs = hub.appending(path: "models--org--weights/blobs")
        let lift = try await lift(FakeRunner(), hub: hub) {
            try? FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
            try? Data(count: 500).write(to: blobs.appending(path: "w.incomplete"))
            Thread.sleep(forTimeInterval: 2.5)
        }
        _ = try await lift.modelsInstall("weighted", confirm: true)
        #expect(try await eventually { try await lift.modelsGet("weighted").progress == InstallProgress(downloadedBytes: 500, totalBytes: 2000) })
        #expect(try await lift.modelsGet("weighted").status == .installing(phase: "downloading weights"))
        #expect(try await eventually {
            let m = try await lift.modelsGet("weighted")
            if case .installing = m.status { return false }
            return m.progress == nil
        })
    }

    @Test func cancellingTheDownloadKeepsTheInstallAndSkipsTheCheck() async throws {
        let hub = try Fixtures.tempDir()
        let lift = try await lift(FakeRunner(), hub: hub) { Thread.sleep(forTimeInterval: 1.5) }
        _ = try await lift.modelsInstall("weighted", confirm: true)
        #expect(try await eventually { try await lift.modelsGet("weighted").status == .installing(phase: "downloading weights") })
        _ = try await lift.modelsCancelInstall("weighted")
        #expect(try await eventually { try await lift.modelsGet("weighted").status == .installed(commit: nil) })  // not weights_missing: no check ran
        await #expect(throws: LiftError.self) { try await lift.modelsCancelInstall("weighted") }  // nothing to cancel now
    }

    @Test func cancellingWhileSettingUpLeavesItNotInstalledRatherThanFailed() async throws {
        let runner = FakeRunner()
        let hub = try Fixtures.tempDir()
        runner.on("pip", effect: { Thread.sleep(forTimeInterval: 1.5) })
        let lift = try await lift(runner, hub: hub) {}
        _ = try await lift.modelsInstall("weighted", confirm: true)
        #expect(try await lift.modelsCancelInstall("weighted").status == .installing(phase: "cancelling"))
        #expect(try await eventually { try await lift.modelsGet("weighted").status == .notInstalled })
        #expect(!runner.displays.contains { $0.contains("download org/weights") })
    }
}

extension InstallerTests {
    @Test func theInstallReportsEachPhaseInOrder() async throws {
        let phases = Mutex<[String]>([])
        try await installer(FakeRunner()).install(try source(), pin: nil, onLine: { _ in }, onPhase: { p in phases.withLock { $0.append(p) } })
        #expect(phases.withLock { $0 } == ["getting the code", "setting up python", "checking the install"])
    }
}

/// hf download's own progress (tqdm, also with hf_xet, which may write a blob only when a file is done).
@Suite struct HFProgressTests {
    @Test func byteBarsAreSummedPerFileAndCountBarsIgnored() {
        var p = HFProgress()
        p.read("Fetching 4 files:   0%|          | 0/4 [00:00<?, ?it/s]", repo: "o/r")  // file count, not bytes
        #expect(p.bytes == 0)
        p.read("model.safetensors:   0%|          | 0.00/4.00G [00:00<?, ?B/s]", repo: "o/r")
        p.read("model.safetensors:  42%|████▏     | 1.68G/4.00G [00:30<00:41, 56.2MB/s]", repo: "o/r")
        p.read("config.json: 100%|██████████| 512/512 [00:00<00:00, 1.20kB/s]", repo: "o/r")
        #expect(p.bytes == 1_680_000_512)
        p.read("model.safetensors:  60%|██████    | 2.40G/4.00G [00:42<00:28, 57.0MB/s]", repo: "o/r")  // the same bar, later
        #expect(p.bytes == 2_400_000_512)
        p.read("model.safetensors:  10%|█         | 503M/5.03G [00:05<00:45, 98.6MB/s]", repo: "o/other")  // another repo's file
        #expect(p.bytes == 2_903_000_512)
        p.read("Downloading 'model.safetensors' to '/hub/models--o--r/blobs/abc.incomplete'", repo: "o/r")  // not a bar
        p.read("pytorch_model.bin:  33%|███▎      | 330kB/1.00MB [00:01<00:02, 330kB/s]", repo: "o/r")
        #expect(p.bytes == 2_903_330_512)
    }
}

extension DownloadsTests {
    @Test func progressFollowsHFsOwnCountWhenTheCacheLagsBehind() async throws {
        let runner = FakeRunner()
        runner.on("hf download", lines: ["w.bin:  40%|████      | 400/1.00k [00:01<00:01, 400B/s]"], delay: .seconds(30))  // xet: no blob yet
        let rig = try await Self.rig(runner: runner)
        _ = try await rig.lift.modelsDownloadWeights("w1", confirm: true)
        #expect(try await eventually { try await rig.lift.downloadsList().first?.downloadedBytes == 400 })
        #expect(try await rig.lift.modelsGet("w1").progress == InstallProgress(downloadedBytes: 400, totalBytes: 1000))
        await rig.lift.close()
    }
}
