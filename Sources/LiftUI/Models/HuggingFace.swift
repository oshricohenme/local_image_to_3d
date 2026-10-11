import Foundation
import LiftCore
import LiftServer
import Observation

/// Hugging Face as Lift uses it: whose key it is, whether it opens a gated repo, and how big a recipe's
/// weights are. Injectable so tests never touch the network.
public protocol HFAccount: Sendable {
    /// The account name, or nil when Hugging Face refuses the key.
    func whoami(token: String) async throws -> String?
    /// Whether the key may download `repo`: true once the user accepted its authors' terms.
    func canAccess(repo: String, token: String) async throws -> Bool
    /// Total bytes of these weights; nil when unknown (offline).
    func size(of weights: [Recipe.Weight]) async -> Int?
}

public struct HuggingFaceAccount: HFAccount {
    let endpoint = URL(string: "https://huggingface.co")!

    public init() {}

    /// `GET /api/whoami-v2`: 200 with the account, 401 for a bad key.
    public func whoami(token: String) async throws -> String? {
        struct Who: Decodable { var name: String }
        let (data, response) = try await request("api/whoami-v2", token: token)
        let status = response.statusCode
        if status == 401 { return nil }
        guard status == 200 else { throw LiftError.invalidState("Hugging Face answered \(status)") }
        return try JSONDecoder().decode(Who.self, from: data).name
    }

    /// `GET /api/models/<repo>/auth-check` with the key as a bearer token, as `huggingface_hub.auth_check` does.
    public func canAccess(repo: String, token: String) async throws -> Bool {
        let (_, response) = try await request("api/models/\(repo)/auth-check", token: token)
        return try Self.access(status: response.statusCode, errorCode: response.value(forHTTPHeaderField: "X-Error-Code"))
    }

    /// Read like `hf_raise_for_status`: `X-Error-Code` first. 200 is granted; `GatedRepo` (401 or 403) or another
    /// 401/403 means the terms aren't accepted yet; `RepoNotFound` or 404 means the repo itself is wrong.
    static func access(status: Int, errorCode: String?) throws -> Bool {
        if errorCode == "RepoNotFound" || status == 404 { throw LiftError.notFound("that model on Hugging Face") }
        if errorCode == "GatedRepo" || status == 401 || status == 403 { return false }
        guard status == 200 else { throw LiftError.invalidState("Hugging Face answered \(status)") }
        return true
    }

    /// The file lists LiftCore verifies against (`HFHubAPI`), summed over each weight's files.
    public func size(of weights: [Recipe.Weight]) async -> Int? {
        let api = HFHubAPI(token: { nil })
        var total = 0
        for w in weights {
            guard let s = try? await api.snapshot(repo: w.repo, revision: w.revision) else { return nil }
            total += s.files.filter { w.files?.contains($0.path) ?? true }.reduce(0) { $0 + $1.size }
        }
        return total
    }

    func request(_ path: String, token: String) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: endpoint.appending(path: path), timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LiftError.invalidState("Hugging Face sent no answer") }
        return (data, http)
    }
}

/// The Hugging Face walkthrough (spec §1): an account, each gated repo's terms, a Read key, then Check. It runs
/// before a gated model's first install (`model` set) and in Settings → Hugging Face (every gated repo).
@MainActor @Observable
public final class HFAccess {
    /// The model about to install, in the install flow.
    public let model: ModelView?
    /// Gated repos, and the attribution component behind each one (same order).
    public let repos: [String]
    public let names: [String]
    public var token = ""
    public private(set) var user: String?
    public private(set) var problem: String?
    public private(set) var repoAccess: [String: Bool] = [:]
    /// Repos whose access couldn't be checked (e.g. the request failed); the others still are.
    public private(set) var unchecked: [String] = []
    public private(set) var busy = false

    public convenience init(_ model: ModelView) {
        self.init(models: [model], model: model)
    }

    /// Every gated repo these models use (Settings).
    public init(models: [ModelView], model: ModelView? = nil) {
        self.model = model
        var names: [String: String] = [:]
        for m in models {
            for w in m.recipe.weights where w.gated {
                names[w.repo] = names[w.repo] ?? m.recipe.attribution.components.first { $0.url.path() == "/" + w.repo }?.name ?? w.repo
            }
        }
        repos = names.keys.sorted()
        self.names = repos.map { names[$0]! }
    }

    /// Check: verifies the pasted key (or the one already kept), keeps it in the Keychain once Hugging Face
    /// accepts it, then asks about each gated repo. A refused key isn't kept.
    public func check(_ app: AppModel) async {
        let pasted = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = pasted.isEmpty ? app.secrets.get(.hfToken) : pasted else { return }
        busy = true
        defer { busy = false }
        problem = nil
        do {
            guard let name = try await app.hf.whoami(token: key) else {
                user = nil
                repoAccess = [:]
                problem = "Hugging Face didn't accept this key. Copy it again from the token page: it starts with “hf_”."
                return
            }
            user = name
            if !pasted.isEmpty {
                _ = try await app.liveServer.secretsSetHFToken(key)
                token = ""
            }
            unchecked = []
            for repo in repos {
                do { repoAccess[repo] = try await app.hf.canAccess(repo: repo, token: key) } catch { unchecked.append(repo) }
            }
        } catch {
            problem = "Lift couldn't reach Hugging Face. Check your internet connection, then press Check again. (\(Format.error(error)))"
        }
    }

    public var granted: Bool { user != nil && waiting.isEmpty }

    /// Repos whose terms aren't accepted (or couldn't be checked) yet.
    public var waiting: [String] { repos.filter { repoAccess[$0] != true } }

    /// A valid key is enough to go on: a repo still waiting only makes its downloads fail until it's accepted.
    public var canContinue: Bool { user != nil }
    public var continueLabel: String { granted ? "Continue" : "Continue anyway" }

    public func notAccepted(_ repo: String) -> String {
        "You haven't accepted the terms for \(repo) yet — downloads for it will fail until you do."
    }
}
