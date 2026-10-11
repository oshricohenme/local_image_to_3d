import Foundation

/// A model's upstream README (spec §4a), as Markdown.
public struct Readme: Codable, Sendable, Equatable {
    public var text: String
    /// Resolves the README's relative links and images at the pinned commit (raw.githubusercontent.com).
    public var baseURL: URL
    /// Served from Lift's cache in the workdir because the network wasn't available.
    public var cached: Bool
}

/// One HTTP GET; injectable so tests never touch the network. Returns nil for a non-200 answer.
public protocol ReadmeHTTP: Sendable {
    func get(_ url: URL) async throws -> Data?
}

public struct URLSessionReadmeHTTP: ReadmeHTTP {
    public init() {}

    public func get(_ url: URL) async throws -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode == 200 ? data : nil
    }
}

/// Finds a recipe's README: Lift's own clone when installed, else raw.githubusercontent.com at the pin,
/// cached in `models/<id>/readme/README.md`; offline, the cache.
public struct ReadmeLoader: Sendable {
    let http: any ReadmeHTTP

    public init(http: any ReadmeHTTP = URLSessionReadmeHTTP()) {
        self.http = http
    }

    /// `modelDir` is `models/<id>/`; `installed` means its `repo/` is the pinned clone. `pin` overrides the
    /// recipe's commit (`models_set_pin`). Nil when the recipe has no GitHub repo or nothing could be read.
    public func load(_ recipe: Recipe, pin: String? = nil, modelDir: URL, installed: Bool) async -> Readme? {
        guard let repo = recipe.repo, let commit = pin ?? recipe.commit, let slug = Self.githubSlug(repo) else { return nil }
        let base = URL(string: "https://raw.githubusercontent.com/\(slug)/\(commit)/")!
        if installed, let local = Self.localReadme(in: modelDir.appending(path: "repo")),
           let text = try? String(contentsOf: local, encoding: .utf8) {
            return Readme(text: text, baseURL: base, cached: false)
        }
        let cache = modelDir.appending(path: "readme/README.md")
        if let data = try? await http.get(base.appending(path: "README.md")), let text = String(data: data, encoding: .utf8) {
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
            return Readme(text: text, baseURL: base, cached: false)
        }
        guard let text = try? String(contentsOf: cache, encoding: .utf8) else { return nil }
        return Readme(text: text, baseURL: base, cached: true)
    }

    /// `owner/name` of a github.com repo URL (with or without `.git`).
    static func githubSlug(_ repo: String) -> String? {
        guard let url = URL(string: repo), url.host() == "github.com" else { return nil }
        let parts = url.path().split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return "\(parts[0])/\(name)"
    }

    /// `README.md`, else any `README.*` (case-insensitive), at the top of the clone.
    static func localReadme(in repo: URL) -> URL? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        let readmes = names.filter { $0.lowercased().hasPrefix("readme") }.sorted()
        let pick = readmes.first { $0.lowercased() == "readme.md" } ?? readmes.first
        return pick.map { repo.appending(path: $0) }
    }
}
