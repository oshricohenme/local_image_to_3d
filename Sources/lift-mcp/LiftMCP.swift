import ArgumentParser
import Foundation


@main
struct LiftMCP: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lift-mcp",
        abstract: "Connects an MCP client that speaks stdio to the running Lift app (Streamable HTTP at /mcp).")

    @Option(help: "Lift's MCP endpoint; server_status shows the actual port.")
    var url = "http://127.0.0.1:7777/mcp"

    @Option(help: "Bearer token, for a Lift on another Mac in LAN mode. Default: $LIFT_TOKEN.")
    var token: String?

    func validate() throws {
        guard URL(string: url)?.scheme?.hasPrefix("http") == true else { throw ValidationError("--url must be an http(s) URL") }
    }

    func run() async throws {
        try await Bridge.run(url: URL(string: url)!, token: token ?? ProcessInfo.processInfo.environment["LIFT_TOKEN"])
    }
}
