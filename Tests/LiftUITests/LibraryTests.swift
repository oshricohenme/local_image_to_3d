import Foundation
@testable import LiftCore
import Testing
@testable import LiftUI

/// The Models library and model page (the approved redesign): what each card and the action card say and offer,
/// with download progress on the card itself.
@MainActor @Suite struct LibraryTests {
    func download(_ state: Download.State, _ bytes: Int = 6_300_000_000, total: Int? = 15_000_000_000, resumed: Bool = false,
                  reason: String? = nil) -> Download {
        Download(id: "d", model: "pixal3d", weights: [], state: state, totalBytes: total, downloadedBytes: bytes, reason: reason, link: nil,
                 attempts: 1, resumed: resumed, position: 1, createdAt: Date(), startedAt: nil, finishedAt: nil)
    }

    func with(_ m: ModelView, _ status: ModelStatus, _ d: Download? = nil) -> ModelView {
        var m = m
        m.status = status
        m.download = d
        return m
    }

    @Test func sectionsFollowWhatTheModelDoesAndFiltersAndSearchNarrowThem() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        let all = Library.sections(app.models, filter: .all, search: "")
        #expect(all.map(\.title) == ["Photo to 3D", "Add-ons for your 3D models"])
        #expect(all[0].models.map(\.id) == ["pixal3d", "trellis2-mac"] && all[1].models.map(\.id) == ["unirig"])
        #expect(Library.sections(app.models, filter: .rigging, search: "").flatMap(\.models).map(\.id) == ["unirig"])
        #expect(Library.sections(app.models, filter: .installed, search: "").isEmpty)  // nothing installed yet
        #expect(Library.sections(app.models, filter: .all, search: "skeleton").flatMap(\.models).map(\.id) == ["unirig"])  // the description
        #expect(Library.sections(app.models, filter: .all, search: "microsoft").flatMap(\.models).map(\.id) == ["trellis2-mac"])  // the authors
        #expect(Library.comingSoon(app.models) == ["Images", "Video", "Audio"])
    }

    @Test func eachCardSaysWhereTheModelStandsAndOffersOneThing() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        let pixal = try #require(app.models.first { $0.id == "pixal3d" })
        #expect(Library.chip(pixal, hfKey: false) == "Needs Hugging Face access" && Library.action(pixal) == .install)
        #expect(Library.chip(pixal, hfKey: true) == "Not installed")
        let installed = with(pixal, .installed(commit: "c"))
        #expect(Library.chip(installed, hfKey: true) == "Installed" && Library.action(installed) == .useInGenerate)
        let downloading = with(pixal, .installing(phase: "downloading weights"), download(.downloading))
        #expect(Library.chip(downloading, hfKey: true) == "Downloading 42%" && Library.action(downloading) == .pause)
        let paused = with(pixal, .installing(phase: "download paused"), download(.paused))
        #expect(Library.chip(paused, hfKey: true) == "Paused" && Library.action(paused) == .resume)
        let waiting = with(pixal, .installing(phase: "waiting to download"), download(.queued))
        #expect(Library.chip(waiting, hfKey: true) == "Waiting to download" && Library.action(waiting) == .downloadNow)
        let failed = with(pixal, .installed(commit: "c"), download(.failed, reason: "Accept briaai/RMBG-2.0's terms on Hugging Face"))
        #expect(Library.chip(failed, hfKey: true) == "Download failed" && Library.action(failed) == .retry)
        let settingUp = with(pixal, .installing(phase: "setting up python"))
        #expect(Library.chip(settingUp, hfKey: true) == "Setting up Python…" && Library.action(settingUp) == nil)
        let unsupported = with(pixal, .unsupported(reason: "needs CUDA"))
        #expect(Library.chip(unsupported, hfKey: true) == "Not supported on this Mac" && Library.action(unsupported) == nil)
    }

    @Test func aDownloadLineSaysHowMuchHowFastAndHowLong() {
        var rate = RateEstimate()
        let t0 = Date()
        rate.add(5_100_000_000, at: t0)
        rate.add(5_220_000_000, at: t0.addingTimeInterval(10))
        #expect(rate.bytesPerSecond == 12_000_000)
        #expect(Format.downloadLine(download(.downloading, 5_220_000_000, total: 20_100_000_000), rate: rate)
                == "5.2 of 20.1 GB · 12 MB/s · about 21 min left")
        #expect(Format.downloadLine(download(.downloading), rate: nil) == "6.3 of 15.0 GB")  // no rate yet
        #expect(Format.downloadLine(download(.downloading, total: nil), rate: nil) == "6.3 GB so far")
        #expect(Format.downloadLine(download(.queued), rate: nil) == "Waiting to download")
        #expect(Format.downloadLine(download(.queued, resumed: true), rate: nil) == "Resuming")
        #expect(Format.downloadLine(download(.paused), rate: nil) == "Paused · 6.3 of 15.0 GB")
        #expect(Format.downloadLine(download(.cancelled), rate: nil) == "Download stopped · 6.3 of 15.0 GB kept")
        #expect(Format.downloadLine(download(.failed, reason: "Lift couldn't reach Hugging Face."), rate: nil) == "Lift couldn't reach Hugging Face.")
    }

    @Test func notEnoughSpaceSaysHowMuchToFreeUp() {
        #expect(Format.spaceWarning(free: 10_000_000_000, remaining: 8_700_000_000) == nil)
        #expect(Format.spaceWarning(free: 4_000_000_000, remaining: 8_700_000_000) == "Not enough space — free up 5 GB")
        #expect(Format.spaceWarning(free: nil, remaining: 8_700_000_000) == nil)
    }

    @Test func aDownloadThatFinishesOrFailsIsNotifiedOnce() {
        let names = ["pixal3d": "Pixal3D"]
        let previous: [String: Download.State] = ["d": .downloading]
        #expect(AppModel.downloadEvents(previous: previous, current: [download(.done)], names: names) == [.downloadFinished(model: "Pixal3D")])
        #expect(AppModel.downloadEvents(previous: previous, current: [download(.failed, reason: "No network")], names: names)
                == [.downloadFailed(model: "Pixal3D", reason: "No network")])
        #expect(AppModel.downloadEvents(previous: ["d": .done], current: [download(.done)], names: names).isEmpty)
        #expect(AppModel.downloadEvents(previous: previous, current: [download(.paused)], names: names).isEmpty)
    }

    @Test func thePreviewIsTheReadmesFirstRealImageAtThePin() throws {
        let base = URL(string: "https://raw.githubusercontent.com/o/p/c0ffee/")!
        let text = """
        # P
        [![arXiv](https://img.shields.io/badge/arXiv-2501-b31b1b.svg)](https://arxiv.org) <img src="assets/logo.svg" width=40>
        <p align="center"><img src="assets/teaser.jpg" width="90%"></p>

        ![demo](docs/demo.png)
        """
        #expect(Library.previewImage(text, base: base)?.absoluteString == "https://raw.githubusercontent.com/o/p/c0ffee/assets/teaser.jpg")
        #expect(Library.previewImage("![x](https://example.com/a.webp)", base: base)?.absoluteString == "https://example.com/a.webp")
        #expect(Library.previewImage("# no images", base: base) == nil)
    }

    @Test func theModelPagesActionCardFollowsTheState() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        let pixal = try #require(app.models.first { $0.id == "pixal3d" })
        #expect(ModelPage.action(pixal) == .notInstalled)
        #expect(ModelPage.action(with(pixal, .installing(phase: "downloading weights"), download(.downloading))) == .downloading)
        #expect(ModelPage.action(with(pixal, .installing(phase: "getting the code"))) == .installing)
        #expect(ModelPage.action(with(pixal, .installed(commit: "c"))) == .ready(updateAvailable: false))
        #expect(ModelPage.action(with(pixal, .updateAvailable(installedCommit: "a", recipeCommit: "b"))) == .ready(updateAvailable: true))
        #expect(ModelPage.action(with(pixal, .installFailed(command: "uv pip install x", exitCode: 1, reason: "Setting up Python failed: no network"))) == .failed("Setting up Python failed: no network"))
        #expect(ModelPage.action(with(pixal, .weightsMissing([])))  == .failed("Some of the model's files are missing. Download them again to fix it."))
        #expect(ModelPage.action(with(pixal, .unsupported(reason: "needs CUDA"))) == .unsupported("needs CUDA"))
        #expect(ModelPage.action(with(pixal, .installed(commit: "c"), download(.failed, reason: "No network"))) == .failed("No network"))
    }

    @Test func useInGenerateSelectsTheModelsTask() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        let cube = try #require(app.models.first { $0.id == "test-cube" })
        app.useInGenerate(cube)
        #expect(app.section == .generate && app.generate.current == TaskRef(recipe: "test-cube", task: "image_to_3d"))
    }
}
