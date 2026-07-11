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
        // 共享核心：ASR 后端协议与实现、音频采集、XPC 协议。app / daemon / bench 共用。
        .target(
            name: "AimeASR",
            dependencies: [
                .product(name: "Qwen3ASR", package: "qwen3-asr-swift"),
                .product(name: "SpeechVAD", package: "qwen3-asr-swift")
            ],
            path: "Sources/AimeASR",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "aime",
            dependencies: ["AimeASR"],
            path: "Sources/aime",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // 推理服务：模型常驻 + 麦克风采集，LaunchAgent（SMAppService）+ XPC MachService。
        // __info_plist 段内嵌麦克风用途说明（无 bundle 的 launchd 可执行体需要）。
        .executableTarget(
            name: "aime-daemon",
            dependencies: ["AimeASR"],
            path: "Sources/aime-daemon",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/daemon-Info.plist",
                ])
            ]
        ),
        // ASR 评测 CLI：swift run aime-bench <wav...>；--suite 跑测试集出 CER 报告
        .executableTarget(
            name: "aime-bench",
            dependencies: [
                "AimeASR",
                .product(name: "AudioCommon", package: "qwen3-asr-swift"),
                .product(name: "SpeechVAD", package: "qwen3-asr-swift")
            ],
            path: "Sources/aime-bench",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
