import Foundation
import Hummingbird
import Yams

/// openapi.yaml, loaded once: the HTTP routes are generated from it, `/openapi.json` serves it, and the
/// MCP tools are read from it (Tools.swift), so both adapters have the same commands and arguments.
enum OpenAPIDocument {
    static let yaml: String = {
        let url = Bundle.module.url(forResource: "openapi", withExtension: "yaml")!
        return try! String(contentsOf: url, encoding: .utf8)
    }()

    /// As JSON. Yams resolves YAML tags, so a quoted `'202'` stays a string.
    static let json: Data = try! JSONSerialization.data(withJSONObject: Yams.load(yaml: yaml)!, options: [.sortedKeys])
}

extension Router where Context == LiftContext {
    /// `/openapi.json` and `/docs`, a Redoc page using the bundled redoc.standalone.js (Redoc 2.5.4, MIT).
    func addDocs() {
        get("/openapi.json") { _, _ in
            Response(status: .ok, headers: [.contentType: "application/json"], body: .init(byteBuffer: ByteBuffer(bytes: OpenAPIDocument.json)))
        }
        get("/docs") { _, _ in
            Response(status: .ok, headers: [.contentType: "text/html; charset=utf-8"], body: .init(byteBuffer: ByteBuffer(string: Self.docsPage)))
        }
        get("/docs/redoc.standalone.js") { _, _ in
            let url = Bundle.module.url(forResource: "redoc.standalone", withExtension: "js", subdirectory: "Resources")!
            return Response(status: .ok, headers: [.contentType: "text/javascript; charset=utf-8", .cacheControl: "max-age=86400"],
                            body: .init(byteBuffer: ByteBuffer(bytes: try Data(contentsOf: url))))
        }
    }

    static var docsPage: String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Lift API</title><style>body { margin: 0 }</style></head>
        <body><redoc spec-url="/openapi.json"></redoc><script src="/docs/redoc.standalone.js"></script></body></html>
        """
    }
}
