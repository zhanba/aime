// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "aime",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        // 锁精确版本：0.0.x API 不稳定，升级需过一遍 Qwen3ASRBackend.swift
        .package(url: "https://github.com/ivan-digital/qwen3-asr-swift", exact: "0.0.21")
    ],
    targets: [
        .executableTarget(
            name: "aime",
            dependencies: [
                .product(name: "Qwen3ASR", package: "qwen3-asr-swift")
            ],
            path: "Sources/aime",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // ASR 评测 CLI：swift run aime-bench <wav...> [--model id] [--context text]
        .executableTarget(
            name: "aime-bench",
            dependencies: [
                .product(name: "Qwen3ASR", package: "qwen3-asr-swift"),
                .product(name: "AudioCommon", package: "qwen3-asr-swift")
            ],
            path: "Sources/aime-bench",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
