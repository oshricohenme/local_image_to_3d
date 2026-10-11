import Foundation
import LiftCore

/// Hugging Face as setup uses it: whose key it is, whether it opens a gated repo, and how big a recipe's
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
        let (data, status) = try await get("api/whoami-v2", token: token)
        if status == 401 { return nil }
        guard status == 200 else { throw LiftError.invalidState("Hugging Face answered \(status)") }
        return try JSONDecoder().decode(Who.self, from: data).name
    }

    /// `GET /api/models/<repo>/auth-check` (what `huggingface_hub.auth_check` uses): 200 granted, 401/403 not yet.
    public func canAccess(repo: String, token: String) async throws -> Bool {
        let (_, status) = try await get("api/models/\(repo)/auth-check", token: token)
        if [401, 403].contains(status) { return false }
        guard status == 200 else { throw LiftError.invalidState("Hugging Face answered \(status) for \(repo)") }
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

    func get(_ path: String, token: String) async throws -> (Data, Int) {
        var request = URLRequest(url: endpoint.appending(path: path), timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
