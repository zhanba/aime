# aime Roadmap

> AI 输入法：语音 + 拼音双模态，中英混输为核心场景，macOS native。
>
> 统一抽象：**noisy signal（语音波形 / 带错拼音）→ 意图恢复（ASR / 拼音解码）→ LLM 精修 → 文本**。
> 两条输入通道共享同一个精修层、上下文层和用户词库，融合发生在数据结构层面，而非功能叠加。

## 产品原则

1. **盲打优先**：整句模式下用户大部分时间不看候选窗，低置信段用视觉样式（虚线/灰色）标记，需要时才处理。
2. **延迟被 UI 吸收**：本地快速层先出字，LLM 精修结果回来后柔和 diff 替换，等待不阻塞打字流。
3. **AI 的每次改写可一键撤回**：提交后可"回改"（重回 composition 态），信任是攒出来的。
4. **默认本地，隐私可感知**：模型优先跑在设备上；读取屏幕上下文/调用 API 时有明确指示，按应用白名单控制。

## 技术决策（已定）

| 决策项 | 选择 | 说明 |
|---|---|---|
| 平台 | macOS first，纯 native | Windows/TSF 明确延后 |
| 语言栈 | Swift 全栈 | SwiftUI + IMKit + 纯 Swift Package 核心（不依赖 AppKit，保留移植性） |
| UI | SwiftUI 设置中心 + AppKit 自绘候选窗/浮层（NSPanel） | |
| 本地推理 | MLX Swift（进程内嵌入，无 Python 运行时） | |
| 默认 ASR | **Qwen3-ASR**（0.6B / 1.7B，Apache 2.0，2026-01 开源） | 经 speech-swift 接入 aufklarer MLX 转换版：0.6B 4-bit（~700MB，默认）/ 1.7B 8-bit（~2.4GB） |
| ASR 基线 | Apple SpeechAnalyzer / SpeechTranscriber（macOS 26） | M1 阶段零依赖跑通全链路 |
| 云端 LLM | OpenAI 兼容 API（DeepSeek / OpenRouter / 本地 Ollama 均可配） | |
| 本地 LLM（后期） | Qwen3 系 1–3B 微调 + 拼音约束解码（MLX 自定义 sampler） | 与 Qwen3-ASR 共享工具链 |
| 分发 | 直接分发 + 公证（notarization）+ Sparkle 自动更新 | 不走 App Store |

## 进程架构

```
┌ aime-ime     (IMKit 进程，系统托管) ── 轻：按键处理、composition 状态机、候选窗
│        ↕ XPC
├ aime-daemon  (推理服务) ───────────── 重：MLX 模型常驻、音频采集+VAD、API 调用、词库
│        ↕
└ aime-app     (主应用) ─────────────── SwiftUI 设置中心、菜单栏、模型下载管理
```

- 麦克风权限归 daemon（IMKit 进程不申请敏感权限）。
- 语音结果经 XPC 进入 IME 的 **composition 预编辑区**，不直接 paste——这是双模态融合的结构基础。
- composition buffer 不存字符串，存**带候选和置信度的片段序列**（拼音 lattice 段 / 语音 n-best 段 / 已确认段），LLM 精修、用户纠错、跨模态修正都操作同一结构。

---

## 里程碑

> **当前状态（2026-07-11）**：M1 ✅、M2 ✅ 全部完成。Qwen3-ASR（0.6B/1.7B）+ VAD 前置 + daemon 常驻架构就绪，评测 1.7B 混说 CER 1.55%（基线 8.98%）。下一步：M3 拼音 IME（前置补课：真人录音测试集、M1 Air 基准、XPC 签名校验）。

### M1 — 语音管线 MVP ✅（2026-07-10 完成，commit `4750704`）

不写 IME，工程风险最低，验证"ASR + LLM 精修"的体验增益。

- [x] menu bar app 骨架（SwiftUI）+ 全局快捷键（按住说话，右 Option/右 Command/Fn 可选）
- [x] 音频采集（AVAudioEngine + RMS 电平；Silero VAD 移入 M2-W3，按住说话模式下起止由用户控制）
- [x] SpeechAnalyzer 基线转写（流式，实时预览进浮层）
- [x] LLM API 精修层：标点、同音字纠错、去填充词、可选书面化；未配 Key 时纯本地
- [x] 上下文采集：Accessibility API 读光标前文本 + 当前应用名，注入精修 prompt
- [x] 文本注入（粘贴+剪贴板保存恢复 / 模拟键入，可选）
- [x] 语音浮层：录音电平 → 转写中 → 精修中 → 完成，四态非激活 NSPanel
- [x] 隐私指示：请求携带上下文时浮层显示图标

**验收**：日常听写可用 ✅；50 句测试集的量化对比未做（并入 M2-W6 一起做）。

### M2 — 接入 Qwen3-ASR（MLX）✅（2026-07-11 完成）

方案见 [docs/M2.md](docs/M2.md)，评测数据见 [docs/M2-bench.md](docs/M2-bench.md)。关键调研结论：直接依赖 speech-swift（锁 0.0.21），不自行移植；开源版**支持** context 偏置（system 槽位），已实测生效（热词精确命中率依赖措辞，M3 调优）。

- [x] W1 ASR 后端协议化（`ASRBackend`/`ASRSession`）：SpeechAnalyzer / Qwen3-ASR 设置中可切换
- [x] W2 集成 speech-swift：0.6B 4-bit 默认档 / 1.7B 8-bit 高质量档；下载进度、磁盘占用/删除/打开目录进设置 UI；本地有权重自动走离线模式（弱网不卡启动）。HF 镜像 endpoint 上游未暴露——手动导入方案兜底（README）
- [x] context 识别偏置端到端接通（光标前文本 → 模型 system 槽位）
- [x] W3 VAD 前置过滤（Silero，MLX）：掐首尾静音 + 纯静音/噪声直接拦截（实测无 VAD 幻觉 2/5 → 有 VAD 0/5）；幻觉后置检测（重复 n-gram、时长比）双防线
- [x] 流式预览（录音中自适应节奏局部重转写）
- [x] W4 置信度调研：上游 argMax 贪心解码不暴露 logprobs，**被上游阻塞**（按计划不设为出口条件；M3 如需可 fork/提 PR）
- [x] W5 daemon 拆分：AimeASR 共享库 + aime-daemon（SMAppService LaunchAgent + MachService XPC）+ app 侧代理与自动回退；实测注册/ping/模型常驻（二次 prepare 0.00s）全通。默认关闭（实验性开关），daemon 麦克风真人链路与 XPC 签名校验留 M3
- [x] W6 50 句混说测试集 + aime-bench：混合 CER / RTF / 峰值内存；**1.7B CER 1.55% vs 基线 8.98%**（TTS 合成音，绝对值偏乐观）

**验收**：引擎可切换 ✅；RTF≪1.0 ✅；混说质量优于 SpeechAnalyzer ✅（5.8×）；静音零幻觉 ✅（5/5 拦截）；daemon 模型常驻 ✅。未覆盖：M1 Air 下限机型基准、真人录音测试集（移入 M3 前置任务）。

**验收**：中英混说质量优于 SpeechAnalyzer 基线（对照 SenseVoice 作参照）；M1 Air 上流式实时率 < 1.0。

### M3 — 拼音 IME

差异化核心：容错在规则层 + LLM 层分工，不裸丢字符串。

- [ ] IMKit 输入法骨架 + 安装/启用引导
- [ ] 拼音切分器：音节 lattice（歧义保留多路径）；非拼音片段识别为英文透传（中英混输）
- [ ] 模糊音扩展（z/zh、n/l、in/ing、an/ang…，设置可按方言勾选）
- [ ] 键盘错误模型：QWERTY 临近键、漏敲/多敲，编辑距离 ≤1 候选
- [ ] LLM 整句转换：结构化 prompt（原始按键 + 切分 + 模糊候选 + 光标前文），180ms 防抖
- [ ] 组合区置信度视觉语言：实线已转换 / 虚线待定 / 英文原样
- [ ] 候选窗（消歧面板）：Tab 跳待定段、数字键选候选、句级备选一行
- [ ] 用户词库 v1：确认过的转换入库，优先排序
- [ ] 设置中心：全拼/双拼、模糊音矩阵、LLM endpoint、Playground 调试区

**验收**：整句盲打首选准确率可用（自建含错拼音测试集）；`nihsoshijie` 类误触可恢复；`zheshiyigeAPIjiekou` 类混输正确切分。

### M4 — 双模态融合

- [ ] 语音入 composition：daemon 转写经 XPC 写入 IME 状态机，与拼音共享片段序列（一次会话内混用两种模态）
- [ ] **回改键**：最近一次提交重回 composition 态，低置信段自动标出（窗口期：上屏 10s 内且光标未移走）
- [ ] 跨模态纠错 v1（无音频版）：选中 ASR 错词敲拼音 → "拼音约束 + n-best 文本"联动重解码整句
- [ ] 语音消歧：待定段上按住说话键说该词（声调补全无声调拼音丢失的信息）
- [ ] 共享词库双向增强：拼音学到的词作 ASR 热词，语音确认的词助拼音排序；设置中心"教它"页
- [ ] 隐私面板：按应用开关矩阵、数据流向说明、一键纯本地模式

**验收**：流程走查三场景全通——纯拼音盲打、语音长段听写+Tab修正、"打字+按住说话+继续打字"混合输入一次提交。

### M5 — 本地化（摆脱 API 延迟与成本）

- [ ] 拼音小模型：Qwen3 系 1–3B 微调，训练数据程序化合成（语料→注音→注入模糊音/键盘噪声）
- [ ] **拼音约束解码**：MLX Swift 自定义 sampler，只允许生成与输入 lattice 匹配的汉字
- [ ] 本地/云端分层：本地即时出字，云端（可选）精修替换
- [ ] （探索）音频级跨模态重解码：拼音修正时携带原始音频信号
- [ ] （探索）统一小模型：同时吃音频与拼音两种噪声信号

**验收**：纯本地模式下逐句延迟 < 100ms；断网完全可用。

---

## 主要风险

| 风险 | 缓解 |
|---|---|
| 拼音 API 往返延迟卡手感 | 整句模式 + 防抖；本地快速层先出字；M5 本地小模型是根本解 |
| LLM-based ASR 静音幻觉 | Silero VAD 前置 + 置信度门槛 |
| 回改键与宿主应用快捷键冲突 | 按键可配置 + 按应用禁用列表 |
| 低置信标记阈值（标多像出疹子） | Playground 收集真实数据调参，做成可调 |
| 输入法读屏 + 发 API 的隐私观感 | 默认本地、按应用白名单、浮层指示、数据流向面板 |
| IMKit 细节坑（composition 兼容性因应用而异） | 早测主流应用矩阵：浏览器、VS Code、微信、Terminal、Office |

## 参考

- [Handy](https://github.com/cjpais/Handy) — 语音管线参考（cpal + Silero VAD + 快捷键 + 注入）
- [ds-input](https://github.com/madeye/ds-input) — LLM 整句拼音 IME 骨架参考（IMKit/TSF 薄前端 + 核心引擎分层）
- [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) · [mlx-qwen3-asr](https://github.com/moona3k/mlx-qwen3-asr) · [qwen3-asr-swift](https://github.com/ivan-digital/qwen3-asr-swift)
- [MLX Swift](https://github.com/ml-explore/mlx-swift)
