# aime

AI 输入法：语音 + 拼音双模态，中英混输为核心场景，macOS native。规划见 [ROADMAP.md](ROADMAP.md)。

当前进度：**M2 完成**。菜单栏应用，按住快捷键说话，本地转写（SpeechAnalyzer 或 Qwen3-ASR/MLX，Silero VAD 前置）→ LLM 精修 → 注入前台应用；可选 aime-daemon 后台服务承载模型常驻（SMAppService + XPC，实验性）。评测见 [docs/M2-bench.md](docs/M2-bench.md)。

## 构建与运行

要求：macOS 26+，Xcode 26+。

```sh
make run          # 构建、打包 build/aime.app 并启动
```

默认用 "Apple Development" 证书签名（保持 TCC 权限在重新构建后不失效）；没有证书时：

```sh
make bundle SIGN_IDENTITY=-
```

## 首次使用

1. 启动后授予**麦克风**权限（自动弹出）和**辅助功能**权限（自动弹出，需在系统设置中勾选）。
2. 首次会自动下载系统语音模型（菜单栏图标显示准备中）。
3. 在任意输入框中，**按住右 Option** 说话，松开完成。Esc 取消。
4. 菜单栏 → 设置：配置 LLM API（OpenAI 兼容，默认 DeepSeek）后启用精修；**API Key 留空则直接使用原始转写**，不发出任何网络请求。

## 架构（M2）

```
Sources/
├── AimeASR/                   共享库（app / daemon / bench 共用）
│   ├── ASRTypes.swift         ASRBackend/ASRSession 协议、ASRSessionConfig、ModelStore
│   ├── AudioRecorder.swift    AVAudioEngine 采集 + 电平（会话自持）
│   ├── SpeechAnalyzerBackend.swift  系统基线引擎（流式）
│   ├── Qwen3ASRBackend.swift  Qwen3-ASR（MLX）+ Silero VAD 前置 + 幻觉检测
│   └── XPCProtocol.swift      daemon XPC 接口定义
├── aime/                      菜单栏应用
│   ├── AppState.swift         会话状态机（idle→recording→transcribing→refining→done）
│   ├── Daemon/                SMAppService 注册、XPC 客户端与代理后端（自动回退进程内）
│   ├── Refine/LLMRefiner.swift  OpenAI 兼容 chat/completions 精修
│   ├── Context/ Inject/ Hotkey/  AX 上下文、文本注入、全局快捷键
│   └── UI/                    浮层（NSPanel 非激活）+ 设置界面（SwiftUI）
├── aime-daemon/               推理服务（LaunchAgent，模型常驻 + 录音，XPC MachService）
└── aime-bench/                评测 CLI（--suite 测试集出混合 CER/RTF/内存报告）
```

评测复现：`./scripts/gen_testset.sh && swift run -c release aime-bench --suite testdata --backend <id> [--vad]`
Daemon 调试：`aime --daemon-status` / `aime --daemon-prepare`；重启用 `make daemon-restart`。

## 隐私

- 语音转写完全在本地（Apple SpeechAnalyzer），音频不离开设备。
- 只有配置了 API Key 时，**转写文本**（及开启上下文时光标前的文本）才会发送到你自己配置的 endpoint；精修请求进行中浮层会显示"已读取上下文"指示。

## Qwen3-ASR 模型下载慢（国内网络）

模型权重从 HuggingFace CDN 下载，单流速度可能很慢。手动加速方式：用多线程工具（aria2c/分段 curl）下载模型文件，放进
`~/Library/Application Support/aime/models/<org>/<name>/`（如 `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`），
需要的文件：`config.json`、`model.safetensors`（或分片 + `model.safetensors.index.json`）、`vocab.json`、`merges.txt`、`tokenizer_config.json`。
目录里存在 `.safetensors` 后，应用会自动走离线模式，不再发起网络请求。

## M1 已知取舍

- Silero VAD 未接入（按住说话模式下由用户控制起止，电平仅用于动画）；VAD 将在 M2 作为 Qwen3-ASR 的幻觉前置过滤引入。
- API Key 暂存 UserDefaults，M2 迁移 Keychain。
- Esc 取消键无法拦截，宿主应用也会收到 Esc。
