// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "aime",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "aime",
            path: "Sources/aime",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
