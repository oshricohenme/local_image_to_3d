import Foundation

/// A recipe's `attribution:` block (spec §4a): who made the model, where it comes from and under which
/// licenses, including everything else it pulls in. Required for every recipe.
public struct Attribution: Codable, Sendable, Equatable {
    public struct License: Codable, Sendable, Equatable {
        /// SPDX id (`MIT`, `CC-BY-NC-4.0`), or `LicenseRef-…` / `NOASSERTION` for licenses SPDX doesn't name.
        public var spdx: String
        public var url: URL
    }

    public struct Paper: Codable, Sendable, Equatable {
        public var title: String
        public var url: URL
        public var bibtex: String?
    }

    /// Weights repos, helper models, Mac ports and libraries the model uses.
    public struct Component: Codable, Sendable, Equatable {
        public var name: String
        /// What it does for this model, e.g. `model weights`, `background removal`, `Mac port`.
        public var role: String
        public var url: URL
        public var license: License
        /// Shown prominently, e.g. `non-commercial`.
        public var restrictions: [String]

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            role = try c.decode(String.self, forKey: .role)
            url = try c.decode(URL.self, forKey: .url)
            license = try c.decode(License.self, forKey: .license)
            restrictions = try c.decodeIfPresent([String].self, forKey: .restrictions) ?? []
        }
    }

    public var project: String
    public var authors: [String]
    public var homepage: URL
    public var repo: URL?
    public var paper: Paper?
    public var license: License
    public var components: [Component]

    enum CodingKeys: String, CodingKey { case project, authors, homepage, repo, paper, license, components, credit, disclaimer }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        project = try c.decode(String.self, forKey: .project)
        authors = try c.decode([String].self, forKey: .authors)
        homepage = try c.decode(URL.self, forKey: .homepage)
        repo = try c.decodeIfPresent(URL.self, forKey: .repo)
        paper = try c.decodeIfPresent(Paper.self, forKey: .paper)
        license = try c.decode(License.self, forKey: .license)
        components = try c.decodeIfPresent([Component].self, forKey: .components) ?? []
    }

    /// Writes the block plus `credit` and `disclaimer`, so HTTP/MCP clients get the exact wording too.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(project, forKey: .project)
        try c.encode(authors, forKey: .authors)
        try c.encode(homepage, forKey: .homepage)
        try c.encodeIfPresent(repo, forKey: .repo)
        try c.encodeIfPresent(paper, forKey: .paper)
        try c.encode(license, forKey: .license)
        try c.encode(components, forKey: .components)
        try c.encode(credit, forKey: .credit)
        try c.encode(disclaimer, forKey: .disclaimer)
    }

    /// "<Project> by <authors> (<license>)".
    public var credit: String { "\(project) by \(authors.joined(separator: ", ")) (\(license.spdx))" }

    /// The fixed wording of spec §4a.
    public var disclaimer: String {
        "\(project) was created by \(authors.joined(separator: ", ")). Lift is an independent app that runs open-source projects "
            + "on your Mac. Lift did not create \(project) and is not affiliated with or endorsed by its authors."
    }

    /// Why the block is incomplete; empty means valid. Field paths are relative to `attribution`.
    public var problems: [String] {
        var out: [String] = []
        func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if blank(project) { out.append("attribution.project is required") }
        if authors.isEmpty || authors.contains(where: blank) { out.append("attribution.authors must list who made it") }
        if blank(license.spdx) { out.append("attribution.license.spdx is required") }
        for url in [homepage, license.url] + (repo.map { [$0] } ?? []) where url.scheme != "https" {
            out.append("attribution: \(url.absoluteString) must be an https URL")
        }
        if let paper, blank(paper.title) { out.append("attribution.paper.title is required") }
        for (i, c) in components.enumerated() {
            if blank(c.name) || blank(c.role) || blank(c.license.spdx) {
                out.append("attribution.components[\(i)] needs a name, a role and a license")
            }
            if c.url.scheme != "https" || c.license.url.scheme != "https" {
                out.append("attribution.components[\(i)] URLs must be https")
            }
        }
        return out
    }
}
