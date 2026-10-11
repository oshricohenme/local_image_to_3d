// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lift",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LiftCore", targets: ["LiftCore"]),
        .library(name: "LiftUI", targets: ["LiftUI"]),
        .library(name: "LiftServer", targets: ["LiftServer"]),
        .executable(name: "lift-mcp", targets: ["lift-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.1"),
        .package(url: "https://github.com/warrenm/GLTFKit2", from: "0.5.15"),
        // Plan 3: the models' READMEs, rendered in full (spec §4a).
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1"),
        // Plan 2: LiftServer (HTTP + MCP) and lift-mcp.
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
        .package(url: "https://github.com/hummingbird-project/hummingbird", from: "2.27.1"),
        .package(url: "https://github.com/apple/swift-openapi-generator", from: "1.14.0"),
        .package(url: "https://github.com/apple/swift-openapi-runtime", from: "1.13.0"),
        .package(url: "https://github.com/swift-server/swift-openapi-hummingbird", from: "2.1.0"),
        // Pre-1.0: a minor release may break the API.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", .upToNextMinor(from: "0.12.1")),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        // Imported directly by LiftServer; already in the graph through Hummingbird.
        .package(url: "https://github.com/apple/swift-nio", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-http-types", from: "1.8.0"),
        .package(url: "https://github.com/apple/swift-log", from: "1.16.1"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle", from: "2.12.1"),
    ],
    targets: [
        .target(name: "LiftCore", dependencies: [
            .product(name: "GLTFKit2", package: "GLTFKit2"),
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Yams", package: "Yams"),
            .product(name: "Subprocess", package: "swift-subprocess"),
        ]),
        .target(
            name: "LiftServer",
            dependencies: [
                "LiftCore",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "OpenAPIRuntime", package: "swift-openapi-runtime"),
                .product(name: "OpenAPIHummingbird", package: "swift-openapi-hummingbird"),
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            resources: [.copy("openapi.yaml"), .copy("Resources")],
            plugins: [.plugin(name: "OpenAPIGenerator", package: "swift-openapi-generator")]
        ),
        .executableTarget(name: "lift-mcp", dependencies: [
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "LiftCoreTests", dependencies: ["LiftCore"]),
        .target(name: "LiftUI", dependencies: [
            "LiftCore",
            "LiftServer",
            .product(name: "GLTFKit2", package: "GLTFKit2"),
            .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        ]),
        .testTarget(name: "LiftUITests", dependencies: ["LiftUI"]),
        .testTarget(name: "LiftServerTests", dependencies: [
            "LiftServer",
            "lift-mcp",
            .product(name: "MCP", package: "swift-sdk"),
        ]),
    ]
)
