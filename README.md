# Aime

**AI 输入法：语音 + 拼音双模态，中英混输为核心场景。macOS 原生。**

说话、打字，随时切换：语音转写和拼音候选出现在同一个组合区，共享上下文和你的个人词库，
还能互相纠错。默认完全本地运行；配置 API Key 后可选接入 LLM，整句润色更自然。

<!-- TODO: 演示 GIF -->
<!-- ![demo](docs/assets/demo.gif) -->

## 功能

- **整句拼音输入**：整句连打不用分词，漏敲、多敲、按错邻键、前后颠倒都能自动纠回来；
  本地毫秒级出字，空格上屏永不等网络，断网照常用；配置 API 后 LLM 对整句柔和精修
- **语音输入**：任意输入框按住右 Option 说话，本地模型实时转写，松开即出字；
  结果进组合区，可与拼音混着编辑后一次上屏
- **跨模态纠错**：语音识别错了字？退格删掉直接用拼音修，Aime 结合原始发音重新猜你想要的词
- **回改键**（Shift+Space）：刚上屏的内容一键拉回组合区，换候选、继续改
- **组合区翻译**（Tab）：中文写到一半按 Tab 直接出英文译文候选，Esc 无损退回
- **越用越懂你**：拼音和语音上屏共同训练个人词库，新词自动进入语音热词与 LLM 上下文
- **隐私可感知**：默认纯本地、零网络请求；联网功能只发文本、永不发音频

## 安装

系统要求：**macOS 26+**（依赖 SpeechAnalyzer 与 MLX），Apple Silicon。

1. 从 [Releases](https://github.com/zhanba/aime/releases) 下载最新 `Aime-x.y.z.dmg`，拖入「应用程序」；
2. 打开 Aime → 设置 → 拼音页 → **安装输入法**；
3. 系统设置 → 键盘 → 输入法 → 添加「Aime拼音」；
4. 可选：设置里配置 OpenAI 兼容 API（DeepSeek / OpenRouter / 本地 Ollama）启用 LLM 整句精修与翻译。

首次使用会按需请求麦克风与辅助功能权限；首次语音输入自动下载本地 ASR 模型
（0.6B 约 700MB）。

<details>
<summary>模型下载慢？（国内网络加速）</summary>

模型权重从 HuggingFace CDN 下载，单流速度可能很慢。手动加速：用多线程工具（aria2c/分段 curl）
下载模型文件，放进 `~/Library/Application Support/aime/models/<org>/<name>/`
（如 `aufklarer/Qwen3-ASR-1.7B-MLX-8bit`），需要 `config.json`、`model.safetensors`
（或分片 + `model.safetensors.index.json`）、`vocab.json`、`merges.txt`、`tokenizer_config.json`。
目录里存在 `.safetensors` 后自动走离线模式。

</details>

## 隐私

- 语音转写**完全在本地**（Qwen3-ASR/MLX 或 Apple SpeechAnalyzer），音频永不离开设备；
- API Key 留空 = 纯本地模式，不发出任何网络请求；
- 配置 API Key 后，仅发送转写文本、拼音分析和（可开关的）光标前文本到**你自己配置的** endpoint；
- API Key 存放在系统钥匙串（Keychain），不落明文配置文件；
- 浮层/组合区对携带上下文的网络请求有明确指示。

## 从源码构建

要求：macOS 26+，Xcode 26+。

```sh
make run            # 构建、打包 build/aime.app 并启动
make install-ime    # 构建并安装输入法到 ~/Library/Input Methods
swift test          # 单测
```

默认用 "Apple Development" 证书签名（保持 TCC 权限在重新构建后不失效）；没有证书时
`make bundle SIGN_IDENTITY=-`。

架构、评测与调试见 [docs/development.md](docs/development.md)，算法原理见
[docs/algorithm.md](docs/algorithm.md)，发布流程见 [docs/release.md](docs/release.md)，
规划见 [ROADMAP.md](ROADMAP.md)。

## 致谢

- [白霜拼音 rime-frost](https://github.com/gaboolic/rime-frost)（GPL-3.0）——本地词库数据来源。
  **不随本仓库/安装包分发**：应用运行时从上游下载并在用户侧编译为二进制词库
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR)（Apache-2.0）与
  [qwen3-asr-swift](https://github.com/ivan-digital/qwen3-asr-swift)——本地语音识别
- [MLX Swift](https://github.com/ml-explore/mlx-swift)——Apple Silicon 本地推理
- [Handy](https://github.com/cjpais/Handy)、[ds-input](https://github.com/madeye/ds-input)——设计参考

## 许可

[MIT](LICENSE)
