# Aime

**AI 输入法：语音 + 拼音双模态，中英混输为核心场景。macOS 原生。**

把两种「带噪信号」——语音波形和带错拼音——统一交给同一套意图恢复与 LLM 精修层，
两条输入通道共享上下文与用户词库，融合发生在数据结构层面。

<!-- TODO: 演示 GIF -->
<!-- ![demo](docs/assets/demo.gif) -->

## 功能

- **整句拼音输入**：切分 lattice + 模糊音 + 键盘错误模型（漏敲/多敲/临近键/换位），本地词库
  Viterbi 毫秒级出字，LLM 整句精修柔和替换；空格上屏永不等网络，断网完全可用
- **语音输入**：任意输入框按住右 Option 说话，本地 Qwen3-ASR（MLX）转写进组合区，
  与拼音段混排、一次上屏；Silero VAD 前置掐静音防幻觉
- **跨模态纠错**：语音段退格反推拼音重解释，用拼音修 ASR 错字；ASR 结果自动消歧分流
- **回改键**（Shift+Space）：刚上屏的内容重回组合区，换候选、继续修
- **组合区翻译**（Tab）：中文组合态一键出英文译文候选，Esc 无损退回
- **用户词库双向学习**：拼音/语音上屏共同学习（时间衰减），注入 ASR 热词与 LLM prompt
- **隐私可感知**：默认纯本地；只有配置 API Key 后才发送**转写文本/拼音分析**（永不发送音频），
  可按应用屏蔽

## 安装

系统要求：**macOS 26+**（依赖 SpeechAnalyzer 与 MLX），Apple Silicon。

1. 从 [Releases](https://github.com/zhanba/aime/releases) 下载最新 `Aime-x.y.z.dmg`，拖入「应用程序」；
2. 打开 Aime → 设置 → 拼音页 → **安装输入法**；
3. 系统设置 → 键盘 → 输入法 → 添加「Aime拼音」；
4. 可选：设置里配置 OpenAI 兼容 API（DeepSeek / OpenRouter / 本地 Ollama）启用 LLM 整句精修与翻译。

首次使用会按需请求麦克风与辅助功能权限；首次语音输入自动下载本地 ASR 模型
（0.6B 约 700MB，国内网络加速方式见下文）。

## 隐私

- 语音转写**完全在本地**（Qwen3-ASR/MLX 或 Apple SpeechAnalyzer），音频永不离开设备；
- API Key 留空 = 纯本地模式，不发出任何网络请求；
- 配置 API Key 后，仅发送转写文本、拼音分析和（可开关的）光标前文本到**你自己配置的** endpoint；
- 可按应用屏蔽（如密码管理器、银行客户端），组合区/浮层有明确的网络请求指示。

## 从源码构建

要求：macOS 26+，Xcode 26+。

```sh
make run            # 构建、打包 build/aime.app 并启动
make install-ime    # 构建并安装输入法到 ~/Library/Input Methods
swift test          # 单测
```

默认用 "Apple Development" 证书签名（保持 TCC 权限在重新构建后不失效）；没有证书时
`make bundle SIGN_IDENTITY=-`。发布流程见 [docs/release.md](docs/release.md)。

### 架构

```
aime-ime.app  (IMKit 输入法) ── 按键处理、组合区状态机、自绘候选条、翻译态
     ↕ XPC
aime-daemon   (推理服务)     ── MLX 模型常驻、音频采集 + VAD（LaunchAgent）
     ↕ XPC
aime.app      (菜单栏主应用) ── SwiftUI 设置中心、语音浮层、模型/词库下载
```

核心库：`AimePinyin`（切分/纠错/词库/Viterbi/LLM 转换/回验）、`AimeASR`（ASR 后端协议
与 Qwen3/SpeechAnalyzer 实现）、`AimeXPC`（轻量 XPC 协议）。原理详解见
[docs/algorithm.md](docs/algorithm.md)，规划见 [ROADMAP.md](ROADMAP.md)。

评测复现：`./scripts/gen_testset.sh && swift run -c release aime-bench --suite testdata --backend <id> [--vad]`
Daemon 调试：`aime --daemon-status` / `aime --daemon-prepare`；重启用 `make daemon-restart`。

### Qwen3-ASR 模型下载慢（国内网络）

模型权重从 HuggingFace CDN 下载，单流速度可能很慢。手动加速：用多线程工具（aria2c/分段 curl）
下载模型文件，放进 `~/Library/Application Support/aime/models/<org>/<name>/`
（如 `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`），需要 `config.json`、`model.safetensors`
（或分片 + `model.safetensors.index.json`）、`vocab.json`、`merges.txt`、`tokenizer_config.json`。
目录里存在 `.safetensors` 后自动走离线模式。

## 致谢

- [白霜拼音 rime-frost](https://github.com/gaboolic/rime-frost)（GPL-3.0）——本地词库数据来源。
  **不随本仓库/安装包分发**：应用运行时从上游下载并在用户侧编译为二进制词库
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)（Apache-2.0）与
  [qwen3-asr-swift](https://github.com/ivan-digital/qwen3-asr-swift)——本地语音识别
- [MLX Swift](https://github.com/ml-explore/mlx-swift)——Apple Silicon 本地推理
- [Handy](https://github.com/cjpais/Handy)、[ds-input](https://github.com/madeye/ds-input)——设计参考

## 许可

[MIT](LICENSE)
