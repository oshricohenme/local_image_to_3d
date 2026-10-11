import LiftCore
import MarkdownUI
import SwiftUI

/// Plain sentences about a model's credits (spec §4a), shared by About and the first-install sheet.
public enum Credits {
    /// One line per restricted component, e.g. "RMBG-2.0 by BRIA AI is licensed CC-BY-NC-4.0: non-commercial."
    public static func restrictions(_ a: Attribution) -> [String] {
        a.components.filter { !$0.restrictions.isEmpty }.map { c in
            "\(c.name) is licensed \(c.license.spdx): \(c.restrictions.joined(separator: "; "))."
        }
    }

    /// "Made with <project> by <authors>" (Queue and History).
    public static func madeWith(_ a: Attribution) -> String {
        "Made with \(a.project) by \(a.authors.joined(separator: ", "))"
    }
}

/// Models → About (spec §4a): who made the model, its paper and licenses, everything it uses, the
/// disclaimer, and the project's own README.
struct AboutView: View {
    let attribution: Attribution
    let readme: Readme?
    let loadingReadme: Bool

    var body: some View {
        let a = attribution
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(a.project).font(.title3).bold()
                Text("by " + a.authors.joined(separator: ", ")).foregroundStyle(.secondary)
                HStack {
                    Link("Project page", destination: a.homepage)
                    if let repo = a.repo { Link("Source code", destination: repo) }
                    Link("License: \(a.license.spdx)", destination: a.license.url)
                }
                .font(.callout)
            }
            ForEach(Credits.restrictions(a), id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if let paper = a.paper {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paper").font(.headline)
                    Link(paper.title, destination: paper.url)
                    if let bibtex = paper.bibtex {
                        DisclosureGroup("Cite (BibTeX)") {
                            Text(bibtex).font(.caption.monospaced()).textSelection(.enabled)
                            Button("Copy BibTeX") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(bibtex, forType: .string)
                            }
                        }
                    }
                }
            }
            if !a.components.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Also uses").font(.headline)
                    ForEach(a.components.indices, id: \.self) { i in
                        let c = a.components[i]
                        HStack(alignment: .firstTextBaseline) {
                            Link(c.name, destination: c.url)
                            Text("· \(c.role) · ").foregroundStyle(.secondary)
                            Link(c.license.spdx, destination: c.license.url)
                            if !c.restrictions.isEmpty { Text(c.restrictions.joined(separator: ", ")).foregroundStyle(.orange) }
                        }
                        .font(.callout)
                    }
                }
            }
            Text(a.disclaimer).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("README").font(.headline)
            if let readme {
                if readme.cached { Text("Saved copy (Lift couldn't reach the internet).").font(.caption).foregroundStyle(.secondary) }
                ReadmeView(readme: readme)
            } else if loadingReadme {
                ProgressView().controlSize(.small)
            } else {
                Text("No README available right now.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical)
    }
}

/// The project's README in full (spec §4a): headings, lists, tables, code and images, with relative links
/// and images resolved at the pinned commit (`Readme.baseURL`). Links open in the browser.
struct ReadmeView: View {
    let readme: Readme

    var body: some View {
        Markdown(readme.text, baseURL: readme.baseURL, imageBaseURL: readme.baseURL)
            .markdownTheme(.gitHub)
            .textSelection(.enabled)
    }
}
