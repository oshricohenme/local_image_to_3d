import Foundation
import LiftCore

/// The Models library's filter chips.
public enum LibraryFilter: String, CaseIterable, Sendable {
    case all = "All", installed = "Installed", photo = "Photo to 3D", rigging = "Rigging"
}

/// The one thing a card offers.
public enum CardAction: Equatable, Sendable {
    case install, useInGenerate, pause, resume, downloadNow, retry
}

/// The Models library (the approved redesign): sections by what a model does, cards with one status chip and
/// one action, and the modalities still to come. Facts only; the user decides (spec principle 2).
public enum Library {
    public struct Section: Equatable, Sendable {
        public var title: String
        public var models: [ModelView]
    }

    /// Photo (or several photos) → 3D model.
    static func isPhotoTo3D(_ m: ModelView) -> Bool {
        m.recipe.tasks.contains { [.image, .imageSet].contains($0.inputs.first?.type) && $0.output == .mesh }
    }

    static func isRigging(_ m: ModelView) -> Bool {
        m.recipe.tasks.contains { $0.output == .riggedMesh }
    }

    public static func sections(_ models: [ModelView], filter: LibraryFilter, search: String) -> [Section] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let shown = models.filter { m in
            let kept = switch filter {
            case .all: true
            case .installed: m.isInstalled
            case .photo: isPhotoTo3D(m)
            case .rigging: isRigging(m)
            }
            let a = m.recipe.attribution
            return kept && (query.isEmpty || ([m.name, m.recipe.description ?? "", a.project] + a.authors).contains {
                $0.localizedCaseInsensitiveContains(query)
            })
        }
        return [Section(title: "Photo to 3D", models: shown.filter(isPhotoTo3D)),
                Section(title: "Add-ons for your 3D models", models: shown.filter { !isPhotoTo3D($0) })]
            .filter { !$0.models.isEmpty }
    }

    /// Modalities Lift's UI already has but no recipe offers yet: "Images", "Video", "Audio".
    public static func comingSoon(_ models: [ModelView]) -> [String] {
        GenerateModel.modalities.filter { id, _ in !models.contains { m in m.recipe.tasks.contains { $0.modality == id } } }
            .map { id, label in id == "image" ? "Images" : label }
    }

    /// The chip over a card's image.
    public static func chip(_ m: ModelView, hfKey: Bool) -> String {
        if let d = m.download {
            switch d.state {
            case .downloading:
                guard let total = d.totalBytes, total > 0 else { return "Downloading" }
                return "Downloading \(d.downloadedBytes * 100 / total)%"
            case .queued: return d.resumed ? "Resuming" : "Waiting to download"
            case .paused: return "Paused"
            case .failed: return "Download failed"
            case .cancelled: return "Download stopped"
            case .done: break
            }
        }
        switch m.status {
        case .installed: return "Installed"
        // Only a change to what the install builds gets here (how it runs updates by itself): say so on the card.
        case .updateAvailable: return "Update available"
        case .installing: return Format.status(m.status)
        case .unsupported: return "Not supported on this Mac"
        case .installFailed: return "Install failed"
        case .weightsMissing, .weightsCorrupt: return "Needs its files again"
        case .notInstalled:
            return m.recipe.weights.contains(where: \.gated) && !hfKey ? "Needs Hugging Face access" : "Not installed"
        }
    }

    /// The card's one primary action; nil while there's nothing to press (setting up, unsupported).
    public static func action(_ m: ModelView) -> CardAction? {
        switch m.download?.state {
        case .downloading?: return .pause
        case .paused?: return .resume
        case .queued?: return .downloadNow
        case .failed?, .cancelled?: return .retry
        case .done?, nil: break
        }
        switch m.status {
        case .installed, .updateAvailable: return .useInGenerate
        case .notInstalled, .installFailed: return .install
        case .weightsMissing, .weightsCorrupt: return .retry
        case .installing, .unsupported: return nil
        }
    }

    /// The README's first real image at the pin (not a badge or an SVG logo), for the card and the page.
    public static func previewImage(_ markdown: String, base: URL) -> URL? {
        let patterns = [#"!\[[^\]]*\]\(\s*<?([^)\s>]+)"#, #"<img[^>]*\ssrc\s*=\s*["']([^"']+)["']"#]
        var found: [(Range<String.Index>, String)] = []
        for p in patterns {
            let regex = try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
            for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)) {
                if let r = Range(match.range(at: 0), in: markdown), let src = Range(match.range(at: 1), in: markdown) {
                    found.append((r, String(markdown[src])))
                }
            }
        }
        let candidates = found.sorted { $0.0.lowerBound < $1.0.lowerBound }.map(\.1)
        return candidates.lazy.compactMap { URL(string: $0, relativeTo: base)?.absoluteURL }.first { url in
            let s = url.absoluteString.lowercased()
            return !url.pathExtension.lowercased().hasPrefix("svg") && !s.contains("shields.io") && !s.contains("badge")
        }
    }
}
