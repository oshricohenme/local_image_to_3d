import Foundation
import LiftCore
import Testing
@testable import LiftUI

/// What an install says while it runs (spec §1: honest progress, in plain words).
@Suite struct InstallProgressTests {
    @Test func phasesReadAsPlainSteps() {
        #expect(Format.installPhase("getting the code") == "Getting the code")
        #expect(Format.installPhase("setting up python") == "Setting up Python")
        #expect(Format.installPhase("checking the install") == "Checking the install")
        #expect(Format.installPhase("downloading weights") == "Downloading the model")
        #expect(Format.installPhase("verifying weights") == "Checking the files")
        #expect(Format.installPhase("cancelling") == "Stopping")
        #expect(Format.installPhase("installing") == "Installing")
        #expect(Format.status(.installing(phase: "setting up python")) == "Setting up Python…")
    }

    @Test func aDownloadSaysHowMuchAndOnlyThenHowLong() {
        let p = InstallProgress(downloadedBytes: 3_200_000_000, totalBytes: 20_100_000_000)
        #expect(Format.installLine("downloading weights", progress: p, secondsLeft: nil) == "Downloading the model — 3.2 of 20.1 GB")
        #expect(Format.installLine("downloading weights", progress: p, secondsLeft: 300) == "Downloading the model — 3.2 of 20.1 GB · about 5 min left")
        #expect(Format.installLine("downloading weights", progress: p, secondsLeft: 20) == "Downloading the model — 3.2 of 20.1 GB · less than a minute left")
        #expect(Format.installLine("setting up python", progress: nil, secondsLeft: nil) == "Setting up Python")
    }

    @Test func theTimeLeftNeedsTenSecondsOfSamples() {
        var rate = RateEstimate()
        let t0 = Date(timeIntervalSince1970: 1_000)
        rate.add(0, at: t0)
        rate.add(50_000_000, at: t0.addingTimeInterval(5))
        #expect(rate.secondsLeft(total: 1_000_000_000) == nil)  // 5 s: too soon to tell
        rate.add(100_000_000, at: t0.addingTimeInterval(10))
        #expect(rate.secondsLeft(total: 1_000_000_000) == 90)  // 10 MB/s, 900 MB to go
        for i in 11...60 { rate.add(100_000_000 + (i - 10) * 20_000_000, at: t0.addingTimeInterval(Double(i))) }
        #expect(rate.secondsLeft(total: 1_100_000_000) == 0)  // done
        #expect(rate.secondsLeft(total: 2_100_000_000) == 50)  // the recent 20 MB/s, not the early 10
    }

    @MainActor @Test func theAppKeepsARatePerDownloadingModel() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        var cube = try #require(app.models.first)
        cube.status = .installing(phase: "downloading weights")
        cube.progress = InstallProgress(downloadedBytes: 0, totalBytes: 1_000_000_000)
        let t0 = Date()
        app.sample([cube], at: t0)
        cube.progress?.downloadedBytes = 100_000_000
        app.sample([cube], at: t0.addingTimeInterval(10))
        #expect(app.installLine(cube) == "Downloading the model — 0.1 of 1.0 GB · about 2 min left")
        cube.progress = nil
        cube.status = .installed(commit: nil)
        app.sample([cube], at: t0.addingTimeInterval(11))
        #expect(app.rates.isEmpty && app.installLine(cube) == nil)
    }
}
