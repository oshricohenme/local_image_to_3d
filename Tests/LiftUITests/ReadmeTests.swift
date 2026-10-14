import Foundation
import LiftCore
import Testing
@testable import LiftUI

@Suite struct ReadmeTests {
    func readme(_ text: String) throws -> Readme {
        let fields: [String: Any] = [
            "text": text,
            "baseURL": "https://raw.githubusercontent.com/TencentARC/Pixal3D/f7cf38429b0bd264f1995f0f8743a88b1c728b94/",
            "cached": false,
        ]
        return try JSONDecoder().decode(Readme.self, from: JSONSerialization.data(withJSONObject: fields))
    }

    /// READMEs mix Markdown with raw HTML (a centered logo, a row of images, badges): it renders as on GitHub.
    @Test func theReadmesHTMLIsKeptAndItsMarkdownRendered() throws {
        let page = ReadmeHTML.page(try readme("""
        <p align="center"><img src="assets/logo.png" width="200"></p>

        # Demo

        | a | b |
        |---|---|
        | 1 | 2 |

        ~~old~~ and https://example.com
        """))
        #expect(page.contains(#"<p align="center"><img src="assets/logo.png" width="200"></p>"#))
        #expect(page.contains("<h1>Demo</h1>") && page.contains("<table>") && page.contains("<del>old</del>"))
        #expect(page.contains(#"<a href="https://example.com">"#))
    }

    /// Relative images and links resolve at the pinned commit.
    @Test func relativeURLsResolveAtThePin() throws {
        let page = ReadmeHTML.page(try readme("![teaser](assets/teaser.png)"))
        #expect(page.contains(#"<base href="https://raw.githubusercontent.com/TencentARC/Pixal3D/f7cf38429b0bd264f1995f0f8743a88b1c728b94/">"#))
        #expect(page.contains(#"<img src="assets/teaser.png" alt="teaser" />"#))
    }

    /// Someone else's page: GitHub's tag filter turns script, iframe, style and the like into text.
    @Test func scriptsAndFramesAreFilteredOut() throws {
        let page = ReadmeHTML.page(try readme("<script>alert(1)</script>\n\n<iframe src=\"https://example.com\"></iframe>"))
        #expect(!page.contains("<script>alert") && !page.contains("<iframe src"))
        #expect(page.contains("&lt;script>alert(1)&lt;/script>"))
    }
}
