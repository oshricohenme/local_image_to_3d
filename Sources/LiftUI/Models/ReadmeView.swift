import AppKit
import cmark_gfm
import cmark_gfm_extensions
import LiftCore
import SwiftUI
import WebKit

/// A README as GitHub shows it (spec §4a): GitHub-flavored Markdown with its raw HTML kept (centered logos,
/// image rows, badges, `<details>`), relative links and images at the pinned commit (`Readme.baseURL`), and
/// GitHub's tag filter on script, iframe, style and the like.
enum ReadmeHTML {
    static func body(_ markdown: String) -> String {
        cmark_gfm_core_extensions_ensure_registered()
        let options = CMARK_OPT_UNSAFE  // keep the README's own HTML; `tagfilter` still disarms the dangerous tags
        guard let parser = cmark_parser_new(options) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter", "tasklist"] {
            if let ext = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, ext) }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let doc = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(doc) }
        guard let html = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        return String(cString: html)
    }

    static func page(_ readme: Readme) -> String {
        let base = readme.baseURL.absoluteString.replacingOccurrences(of: "\"", with: "%22")
        return """
        <!doctype html><html><head><meta charset="utf-8"><base href="\(base)"><style>\(css)</style></head>
        <body>\(body(readme.text))</body></html>
        """
    }

    static let css = """
    :root { color-scheme: light dark; }
    body { margin: 0; font: 14px/1.55 -apple-system, BlinkMacSystemFont, sans-serif; color: CanvasText; background: transparent;
           overflow-wrap: break-word; }
    a { color: LinkText; }
    img, video { max-width: 100%; height: auto; }
    h1, h2 { border-bottom: 1px solid color-mix(in srgb, CanvasText 15%, transparent); padding-bottom: .3em; }
    h1 { font-size: 1.7em; } h2 { font-size: 1.4em; } h1, h2, h3 { margin: 1.2em 0 .5em; }
    code, pre { font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
    code { background: color-mix(in srgb, CanvasText 8%, transparent); padding: .15em .35em; border-radius: 4px; }
    pre { background: color-mix(in srgb, CanvasText 6%, transparent); padding: 12px; border-radius: 8px; overflow-x: auto; }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; display: block; overflow-x: auto; }
    th, td { border: 1px solid color-mix(in srgb, CanvasText 18%, transparent); padding: 5px 10px; }
    blockquote { margin: 0; padding: 0 1em; border-left: 3px solid color-mix(in srgb, CanvasText 20%, transparent); opacity: .85; }
    details summary { cursor: pointer; }
    """
}

/// The README in a web view that is as tall as its content, so the model page scrolls as one. The page's
/// own scripts never run; links open in the browser.
struct ReadmeView: View {
    let readme: Readme
    @State private var height: CGFloat = 200

    var body: some View {
        ReadmeWebView(html: ReadmeHTML.page(readme), baseURL: readme.baseURL, height: $height)
            .frame(height: height)
    }
}

struct ReadmeWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        // Lift's own script, in its own world (the page's scripts are off): report the content's height as it
        // changes, e.g. when images arrive.
        let report = WKUserScript(source: """
            new ResizeObserver(() => webkit.messageHandlers.height.postMessage(document.documentElement.scrollHeight))
                .observe(document.documentElement);
            """, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        config.userContentController.addUserScript(report)
        config.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "height")
        let view = PageScrollingWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != html else { return }
        context.coordinator.loaded = html
        view.loadHTMLString(html, baseURL: baseURL)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let height: Binding<CGFloat>
        var loaded: String?

        init(height: Binding<CGFloat>) { self.height = height }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let h = message.body as? Double, h > 0 { height.wrappedValue = h }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard action.navigationType == .linkActivated, let url = action.request.url else { return .allow }
            var page = URLComponents(url: url, resolvingAgainstBaseURL: false)
            page?.fragment = nil
            if url.fragment != nil, page?.url == webView.url { return .cancel }  // an in-page anchor: the page is shown whole
            NSWorkspace.shared.open(url)
            return .cancel
        }
    }
}

/// Sized to its content, so scrolling over it scrolls the model page instead.
final class PageScrollingWebView: WKWebView {
    override func scrollWheel(with event: NSEvent) { nextResponder?.scrollWheel(with: event) }
}
