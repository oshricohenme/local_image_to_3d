import Foundation
import LiftCore
import MarkdownUI
import SwiftUI
import Testing
@testable import LiftUI

/// Records the image URLs the README view asks for.
@MainActor final class SeenURLs { var urls: [URL] = [] }

struct CapturingImages: ImageProvider {
    let seen: SeenURLs
    func makeImage(url: URL?) -> some View {
        if let url { MainActor.assumeIsolated { seen.urls.append(url) } }
        return Color.clear.frame(width: 10, height: 10)
    }
}

@MainActor @Suite struct ReadmeTests {
    @Test func relativeImagesResolveToThePinnedRawURL() throws {
        let fields: [String: Any] = [
            "text": "# Demo\n\n![teaser](assets/teaser.png)\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n![abs](https://example.com/x.png)",
            "baseURL": "https://raw.githubusercontent.com/TencentARC/Pixal3D/f7cf38429b0bd264f1995f0f8743a88b1c728b94/",
            "cached": false,
        ]
        let readme = try JSONDecoder().decode(Readme.self, from: JSONSerialization.data(withJSONObject: fields))
        let seen = SeenURLs()
        let renderer = ImageRenderer(content: ReadmeView(readme: readme).markdownImageProvider(CapturingImages(seen: seen)).frame(width: 600))
        _ = renderer.nsImage
        #expect(seen.urls.map(\.absoluteString).contains(
            "https://raw.githubusercontent.com/TencentARC/Pixal3D/f7cf38429b0bd264f1995f0f8743a88b1c728b94/assets/teaser.png"))
        #expect(seen.urls.map(\.absoluteString).contains("https://example.com/x.png"))
    }
}
