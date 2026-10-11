// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Lift",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "LiftCore", targets: ["LiftCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.11.1"),
        .package(url: "https://github.com/jpsim/Yams", from: "6.2.2"),
        .package(url: "https://github.com/swiftlang/swift-subprocess", from: "1.0.1"),
    ],
    targets: [
        .target(name: "LiftCore", dependencies: [
            .product(name: "GRDB", package: "GRDB.swift"),
            .product(name: "Yams", package: "Yams"),
            .product(name: "Subprocess", package: "swift-subprocess"),
        ]),
        .testTarget(name: "LiftCoreTests", dependencies: ["LiftCore"]),
    ]
)
