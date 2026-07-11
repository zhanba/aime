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
        // 轻量 XPC 层：协议 + 客户端 + 数据类型。IME 进程只依赖它（不拖 MLX）。
        .target(
            name: "AimeXPC",
            path: "Sources/AimeXPC",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // 共享核心：ASR 后端协议与实现、音频采集。app / daemon / bench 共用。
        .target(
            name: "AimeASR",
            dependencies: [
                "AimeXPC",
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
            dependencies: ["AimeASR", "AimePinyin"],
            path: "Sources/aime",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // 拼音引擎：音节表 / 切分 lattice / 模糊音 / 键盘错误模型 / LLM 整句转换 / 用户词库。
        // 无重依赖（不含 MLX），IME 进程保持轻量。
        .target(
            name: "AimePinyin",
            path: "Sources/AimePinyin",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "AimePinyinTests",
            dependencies: ["AimePinyin"],
            path: "Tests/AimePinyinTests",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // IMKit 输入法（thin：按键状态机 + 组合区 + 候选窗，转换走 AimePinyin）
        .executableTarget(
            name: "aime-ime",
            dependencies: ["AimePinyin", "AimeXPC"],
            path: "Sources/aime-ime",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // 拼音评测 CLI：swift run aime-pinyin <input> / --suite testdata/pinyin_testset.tsv
        .executableTarget(
            name: "aime-pinyin",
            dependencies: ["AimePinyin"],
            path: "Sources/aime-pinyin",
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
