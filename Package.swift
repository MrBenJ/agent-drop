// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentDrop",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentDropCore", targets: ["AgentDropCore"]),
        .library(name: "AgentDropServer", targets: ["AgentDropServer"]),
        .executable(name: "drop", targets: ["drop"]),
        // The macOS app's executable; Scripts/build-app.sh wraps it into AgentDrop.app.
        .executable(name: "AgentDrop", targets: ["AgentDrop"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-service-context.git", from: "1.1.0"),
        // GFM Markdown → HTML for the app's rendered view. swift-cmark has no semver tags
        // (only swift-x.y-RELEASE), so it is pinned to a commit on its `gfm` branch.
        .package(url: "https://github.com/swiftlang/swift-cmark.git", revision: "56146aeeecbfb7ea54504ac6453ac4cbc0faffe7"),
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
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
                // Hummingbird imports ServiceContextModule but only gets it transitively;
                // without this, packages that depend on AgentDropServer fail to build it.
                .product(name: "ServiceContextModule", package: "swift-service-context"),
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
        // Everything in the app that can be tested without a window: models, rendering,
        // settings. The SwiftUI views live in the AgentDrop executable target.
        .target(
            name: "AgentDropApp",
            dependencies: [
                "AgentDropCore",
                "AgentDropServer",
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark"),
            ]
        ),
        .executableTarget(name: "AgentDrop", dependencies: ["AgentDropApp", "AgentDropCore", "AgentDropServer"]),
        // Windowless development stand-in for AgentDrop.app. Not a shipped product.
        .executableTarget(name: "agentdrop-devhost", dependencies: ["AgentDropServer", "AgentDropCore"]),
        .testTarget(
            name: "AgentDropCoreTests",
            dependencies: ["AgentDropCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(name: "AgentDropServerTests", dependencies: ["AgentDropServer", "AgentDropCore"]),
        .testTarget(name: "dropCLITests", dependencies: ["DropCLI", "AgentDropCore", "AgentDropServer"]),
        .testTarget(name: "AgentDropAppTests", dependencies: ["AgentDropApp", "AgentDropCore", "AgentDropServer", "DropCLI"]),
    ]
)
