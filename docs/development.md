# 开发指南

构建命令与签名说明见 [README](../README.md#从源码构建)。

## 架构

```
aime-ime.app  (IMKit 输入法) ── 按键处理、组合区状态机、自绘候选条、翻译态
     ↕ XPC
aime-daemon   (推理服务)     ── MLX 模型常驻、音频采集 + VAD（LaunchAgent）
     ↕ XPC
aime.app      (菜单栏主应用) ── SwiftUI 设置中心、语音浮层、模型/词库下载
```

核心库：

- `AimePinyin` — 切分 lattice、模糊音与键盘错误模型（漏敲/多敲/临近键/换位）、
  用户词库（时间衰减）、Viterbi 解码、LLM 转换与回验
- `AimeASR` — ASR 后端协议与 Qwen3-ASR（MLX）/ Apple SpeechAnalyzer 实现，
  Silero VAD 前置掐静音防幻觉
- `AimeXPC` — 轻量 XPC 协议

原理详解见 [algorithm.md](algorithm.md)。

## 评测复现

```sh
./scripts/gen_testset.sh
swift run -c release aime-bench --suite testdata --backend <id> [--vad]
```

## Daemon 调试

```sh
aime --daemon-status    # 查看状态
aime --daemon-prepare   # 预热模型
make daemon-restart     # 重启
```
