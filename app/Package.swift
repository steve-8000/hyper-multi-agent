// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HyperAI",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "HyperAI",
            targets: ["HyperAI"]
        )
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "HyperAI",
            dependencies: [],
            path: "Sources",
            resources: [
                .copy("Resources")
            ]
        )
    ]
)
