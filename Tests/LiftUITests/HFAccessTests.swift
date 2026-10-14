import Foundation
import LiftCore
import LiftServer
import Testing
@testable import LiftUI

/// The Hugging Face walkthrough (spec §1): account, each gated repo's terms, a Read key, then Check. It runs
/// in a gated model's install flow and in Settings → Hugging Face, never in setup.
@MainActor @Suite struct HFAccessTests {
    @Test func aGatedModelsFirstInstallWalksThroughHuggingFaceFirst() async throws {
        let app = try await UIFixtures.devApp(hf: FakeHF(users: ["hf_good": "ada"], access: ["briaai/RMBG-2.0": true]))
        defer { Task { await app.close() } }
        let pixal = try #require(app.models.first { $0.id == "pixal3d" })
        app.install(pixal)
        #expect(app.aboutBeforeInstall?.id == "pixal3d")  // who made it, first
        app.continueInstall()
        let access = try #require(app.accessBeforeInstall)  // then the key, which the install needs
        #expect(access.repos == ["briaai/RMBG-2.0"] && access.names == ["RMBG-2.0 by BRIA AI"] && access.model?.id == "pixal3d")
        #expect(!access.granted && app.confirmation == nil)
        access.token = "hf_good"
        await access.check(app)
        #expect(access.user == "ada" && access.repoAccess == ["briaai/RMBG-2.0": true] && access.granted)
        #expect(app.secrets.get(.hfToken) == "hf_good" && access.token.isEmpty)
        app.continueAfterAccess()
        #expect(app.accessBeforeInstall == nil)
        #expect(try await eventually { app.confirmation?.message.contains("Pixal3D") == true })  // then the install's own confirmation
    }

    @Test func withAKeyAlreadyKeptTheInstallGoesStraightOn() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        try app.secrets.set(.hfToken, "hf_kept")
        let pixal = try #require(app.models.first { $0.id == "pixal3d" })
        app.install(pixal)
        app.continueInstall()
        #expect(app.accessBeforeInstall == nil)
        #expect(try await eventually { app.confirmation?.message.contains("Pixal3D") == true })
    }

    @Test func aModelWithoutGatedWeightsNeverAsks() async throws {
        let app = try await UIFixtures.app()
        defer { Task { await app.close() } }
        let cube = try #require(app.models.first { $0.id == "test-cube" })
        app.install(cube)
        app.continueInstall()
        #expect(app.accessBeforeInstall == nil)
        #expect(try await eventually { app.confirmation != nil })
    }

    @Test func aBadKeyIsRefusedAndNotKept() async throws {
        let app = try await UIFixtures.devApp(hf: FakeHF(users: ["hf_good": "ada"]))
        defer { Task { await app.close() } }
        let access = HFAccess(app.models.first { $0.id == "trellis2-mac" }!)
        access.token = "hf_typo"
        await access.check(app)
        #expect(access.user == nil && access.problem != nil && !access.granted)
        #expect(app.secrets.get(.hfToken) == nil)
    }

    @Test func aGoodKeyWithOneRepoStillWaitingIsNotGranted() async throws {
        let hf = FakeHF(users: ["hf_good": "ada"], access: ["facebook/dinov3-vitl16-pretrain-lvd1689m": true, "briaai/RMBG-2.0": false])
        let app = try await UIFixtures.devApp(hf: hf)
        defer { Task { await app.close() } }
        let access = HFAccess(app.models.first { $0.id == "trellis2-mac" }!)
        #expect(access.names == ["RMBG-2.0 by BRIA AI", "DINOv3 ViT-L/16 by Meta"])  // in repo order
        access.token = "hf_good"
        await access.check(app)
        #expect(access.user == "ada" && access.problem == nil && app.secrets.get(.hfToken) == "hf_good")
        #expect(access.repoAccess == ["facebook/dinov3-vitl16-pretrain-lvd1689m": true, "briaai/RMBG-2.0": false] && !access.granted)
    }

    @Test func aValidKeyAlwaysAllowsContinueAndSaysWhichTermsAreStillOpen() async throws {
        let dino = "facebook/dinov3-vitl16-pretrain-lvd1689m", rmbg = "briaai/RMBG-2.0"
        for (granted, label, waiting) in [([String: Bool](), "Continue anyway", [rmbg, dino]), ([rmbg: true], "Continue anyway", [dino]),
                                          ([rmbg: true, dino: true], "Continue", [])] {
            let app = try await UIFixtures.devApp(hf: FakeHF(users: ["hf_good": "ada"], access: granted))
            let access = HFAccess(app.models.first { $0.id == "trellis2-mac" }!)
            access.token = "hf_good"
            await access.check(app)
            #expect(access.canContinue && access.continueLabel == label && access.waiting == waiting, "\(granted)")
            #expect(access.waiting.map(access.notAccepted) == waiting.map {
                "You haven't accepted the terms for \($0) yet — downloads for it will fail until you do."
            })
            await app.close()
        }
    }

    @Test func anInvalidKeyKeepsContinueOff() async throws {
        let app = try await UIFixtures.devApp(hf: FakeHF(users: ["hf_good": "ada"], access: ["briaai/RMBG-2.0": true]))
        defer { Task { await app.close() } }
        let access = HFAccess(app.models.first { $0.id == "pixal3d" }!)
        #expect(!access.canContinue)  // nothing checked yet
        access.token = "hf_typo"
        await access.check(app)
        #expect(!access.canContinue && access.continueLabel == "Continue anyway")
    }

    @Test func oneRepoThatCantBeCheckedDoesntSinkTheOthers() async throws {
        struct Flaky: HFAccount {
            func whoami(token: String) async throws -> String? { "ada" }
            func canAccess(repo: String, token: String) async throws -> Bool {
                if repo == "briaai/RMBG-2.0" { throw LiftError.notFound("briaai/RMBG-2.0 on Hugging Face") }
                return true
            }
            func size(of weights: [Recipe.Weight]) async -> Int? { nil }
        }
        let app = try await UIFixtures.devApp(hf: Flaky())
        defer { Task { await app.close() } }
        let access = HFAccess(app.models.first { $0.id == "trellis2-mac" }!)
        access.token = "hf_any"
        await access.check(app)
        #expect(access.repoAccess == ["facebook/dinov3-vitl16-pretrain-lvd1689m": true] && access.problem == nil)
        #expect(access.unchecked == ["briaai/RMBG-2.0"] && access.canContinue)
    }

    /// The answers of `/api/models/<repo>/auth-check`, read the way huggingface_hub's `auth_check` does: the
    /// `X-Error-Code` header first (a gated repo you haven't accepted is 401 or 403 with `GatedRepo`).
    @Test func authCheckAnswersMapLikeHuggingFaceHub() throws {
        #expect(try HuggingFaceAccount.access(status: 200, errorCode: nil))
        #expect(try !HuggingFaceAccount.access(status: 403, errorCode: "GatedRepo"))
        #expect(try !HuggingFaceAccount.access(status: 401, errorCode: "GatedRepo"))
        #expect(try !HuggingFaceAccount.access(status: 403, errorCode: nil))
        #expect(throws: LiftError.self) { try HuggingFaceAccount.access(status: 404, errorCode: "RepoNotFound") }
        #expect(throws: LiftError.self) { try HuggingFaceAccount.access(status: 401, errorCode: "RepoNotFound") }
        #expect(throws: LiftError.self) { try HuggingFaceAccount.access(status: 500, errorCode: nil) }
    }

    @Test func settingsCoversEveryGatedRepoAndChecksTheKeptKey() async throws {
        let app = try await UIFixtures.devApp(hf: FakeHF(users: ["hf_kept": "ada"], access: ["briaai/RMBG-2.0": true]))
        defer { Task { await app.close() } }
        try app.secrets.set(.hfToken, "hf_kept")
        let access = HFAccess(models: app.models)
        let gated = Set(app.models.flatMap { $0.recipe.weights.filter(\.gated).map(\.repo) }).sorted()
        #expect(access.repos == gated && access.model == nil)
        #expect(gated.contains("briaai/RMBG-2.0") && gated.contains("stabilityai/stable-diffusion-3.5-medium"))
        await access.check(app)  // nothing typed: the key Lift already keeps
        #expect(access.user == "ada" && access.repoAccess == Dictionary(uniqueKeysWithValues: gated.map { ($0, $0 == "briaai/RMBG-2.0") }))
    }
}

@MainActor @Suite struct ModelCardTests {
    @Test func aModelsCardSaysWhatItDoesWhatItNeedsAndItsLimits() async throws {
        let app = try await UIFixtures.devApp()
        defer { Task { await app.close() } }
        let pixal = ModelCard(try #require(app.models.first { $0.id == "pixal3d" }), weightsBytes: nil)
        #expect(pixal.task == "Photo → 3D model" && pixal.credit.hasPrefix("by Dong-Yang Li") && pixal.credit.hasSuffix("· MIT"))
        #expect(pixal.gated == ["briaai/RMBG-2.0"])
        #expect(pixal.restrictions.contains("Not for commercial use: RMBG-2.0 by BRIA AI (CC-BY-NC-4.0)"))
        #expect(pixal.restrictions.filter { $0.hasPrefix("DINOv3") }.count == 1)  // one line per component
        #expect(pixal.size == "About 3 GB")  // the recipe's estimate while the weights' size is unknown
        #expect(ModelCard(app.models.first { $0.id == "pixal3d" }!, weightsBytes: 14_200_000_000).size == "About 14.2 GB")
        #expect(ModelCard(app.models.first { $0.id == "unirig" }!, weightsBytes: nil).gated.isEmpty)
    }
}
