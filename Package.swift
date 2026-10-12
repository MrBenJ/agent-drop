// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDrop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDropCore", targets: ["AgentDropCore"]),
        .library(name: "AgentDropServer", targets: ["AgentDropServer"]),
        .executable(name: "drop", targets: ["drop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "AgentDropCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(
            name: "AgentDropServer",
            dependencies: [
                "AgentDropCore",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdCore", package: "hummingbird"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "DropCLI",
            dependencies: [
                "AgentDropCore",
                "AgentDropServer",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "drop", dependencies: ["DropCLI"]),
        .testTarget(
            name: "AgentDropCoreTests",
            dependencies: ["AgentDropCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "AgentDropServerTests", dependencies: ["AgentDropServer", "AgentDropCore"]),
        .testTarget(name: "dropCLITests", dependencies: ["DropCLI", "AgentDropCore", "AgentDropServer"]),
    ]
)
