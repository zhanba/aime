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

> **发布流水线（2026-07-12）**：签名/打包/公证链路已就绪（[docs/release.md](docs/release.md)）——Hardened Runtime + entitlements、XPC audit token 校验、IME 内嵌 app 一键安装（IMEInstaller）、`scripts/release.sh`（版本注入→签名→公证→DMG→staple）。发布剩余门槛：Developer ID 证书（需付费开发者账号）、Sparkle 自动更新、LICENSE、实机走查与兼容矩阵。
>
> **当前状态（2026-07-18）**：M1 ✅、M2 ✅、M3 ✅、M3.5 ✅、M4 ✅（代码完成，实机走查清单待用户）（拼音容错强化+词库层，方案 [docs/M3.5-plan.md](docs/M3.5-plan.md)、原理 [docs/algorithm.md](docs/algorithm.md)）。四层架构落地：拼写变换统一框架（漏敲/多敲/句尾 partial）+ 白霜词库 37 万条 + **LMDG 语法模型（beam Viterbi，2026-07-18，[algorithm.md §4.5](docs/algorithm.md)）** + LLM 整句 + 音节回验；自绘候选条 + 逐段确认。560 句评测：本地整句 39.5% → 50.0%（分发版，gram-v1 release 已发布，启动自动下载 73MB）；旧 40 句含错集：首选 85%，句级覆盖 92%。下一步：简拼（P0 第二项）、M5 本地化（拼音小模型+约束解码，可先用 Qwen3-0.6B 量化 spike）；欠账：M4 实机走查、真人录音测试集（ASR 评测现用 TTS 合成音，绝对值偏乐观）、M1 Air 基准、XPC 签名校验、IME 实机走查、LLM p50 0.97s 待优化。双拼明确不做（用户决策 2026-07-11）；词库下载 UI 已完成。

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

### M3 — 拼音 IME ✅（2026-07-11 完成，记录见 [docs/M3.md](docs/M3.md)）

差异化核心：容错在规则层 + LLM 层分工，不裸丢字符串。

- [x] IMKit 输入法骨架（aime-ime.app）+ `make install-ime` 一键安装/TIS 注册启用 + 设置页引导
- [x] 拼音切分器：DP 音节 lattice；大写/数字/不可解析段透传（中英混输）
- [x] 模糊音扩展：11 组规则、设置页矩阵勾选（默认开南方六组）
- [x] 键盘错误模型：QWERTY 临近键替换 + 相邻换位（漏敲/多敲留后续）
- [x] LLM 整句转换：结构化 prompt（原始按键 + 切分 + 模糊/手误标注 + 光标前文 + 用户词库），180ms 防抖，硬约束逐音节转写
- [x] 组合区样式：转换预览实线下划线 / 未转换拼音点线下划线
- [x] 候选窗（IMKCandidates）：数字选候选、句级备选、原始拼音兜底（Tab 跳段留 M4）
- [x] 用户词库 v1：上屏文本的英文术语与短句入库，注入 prompt 优先采用
- [x] 设置中心拼音页：模糊音矩阵 + Playground 调试区（双拼：不做，用户决策）

**验收**：单测 12/12 ✅；`nihsoshijie`→你好世界 ✅；`zheshiyigeAPIjiekou`→这是一个API接口 ✅；20 句含错测试集首选准确率 85–90%（p50 0.55s）✅。未覆盖：实机各应用兼容性走查（需真实使用反馈）。

### M4 — 双模态融合 ✅（2026-07-11 代码完成，实机走查待用户，方案 [docs/M4-plan.md](docs/M4-plan.md)）

- [x] 语音入 composition：IME 处理右 Option（flagsChanged），经 XPC 直连 daemon 流式进组合区，定稿入确认栈（source=voice）；确认栈结构化支持双模态混排一次提交
- [x] **回改键**（Shift+Space）：刚上屏内容重回 composition（守卫：10s 内 + 光标未移动），恢复完整组合状态可换候选
- [x] 跨模态纠错 v1：语音段退格 → 纯中文反推拼音进 buffer，整套拼音机器（词候选/逐段确认/LLM）直接可用修错字
- [x] 语音消歧：无模式切换——ASR 结果过回验器自动分流（音节匹配→替换预览并补全声调信息；不匹配→追加语音段）
- [x] 共享词库双向增强：拼音/语音上屏共同学习（时间衰减评分），注入 ASR contextHint 热词与 LLM prompt；设置中心"教它"页（列表/删除/手动添加）
- [x] 隐私面板：按应用屏蔽矩阵（bundle id，IME 按 client、app 按前台执行）、纯本地模式一键禁 LLM、数据流向说明
- [x] 基础设施：AimeXPC 轻量模块（IME 不拖 MLX）、daemon XPC 连接方 Team ID 签名校验（M2 欠账清偿）、热键按当前输入源分流、daemon 转正默认启用

**验收**：单测 32/32 ✅；三场景实机走查清单见 [docs/M4-walkthrough.md](docs/M4-walkthrough.md)（需用户实测——flagsChanged 宿主兼容性、语音手感、回改在各应用的行为）。已知边界：语音段含英文时退格为整段删除；pid 基础的签名校验留正式分发前换 audit token。

### M5 — 本地化（摆脱 API 延迟与成本）

> **2026-07-20 超参过 holdout**：形态 A 默认参数改为 beam16 / prior 0 / fuzzyPenalty 3.0（prior 系调参集过拟合，归零）。
> 四集数字：调参集 560 句 81.2%、开发集 238 句 67.2%、模糊噪声集 63.0%、盲测集 147 句 61.2%（p50 247ms；各集本地基线 50.9%/41.2%/40.8%/31.3%）。
> 评测集角色纪律见 `Sources/aime-llm/main.swift` 头注释；盲测集 `testdata/pinyin_blind.tsv` 不得用于调参。
> 剩余高频错误：的/得类准歧义、切分变体——上下文注入与微调（形态 C）的目标。
>
> **2026-07-20 分发与开关**：LocalLLMInstaller（model.safetensors 单文件 ~320MB，HF 主源 + hf-mirror 回退，
> 流式下载+safetensors 校验）+ 设置页拼音 tab"本地整句模型"区（下载管理 + 开关，开时未装自动下载）；
> daemon 资源缺失类加载失败改为可重试（下载补齐后无需重启 daemon）。
>
> **2026-07-20 上下文注入解码**：光标前文（CJK 词元贪心编码，取末 24 字）接在固定 prompt KV 后增量
> prefill，beam 从上下文态起步。消歧集（testdata/pinyin_context.tsv，36 例成对反事实）44.4% → 66.7%，
> 他/她成对翻转全对；无上下文路径零漂移（holdout 67.2% 不变），开销 ~6ms。IME 侧读屏尊重按应用屏蔽。

- [ ] 拼音小模型：Qwen3 系 1–3B 微调，训练数据程序化合成（语料→注音→注入模糊音/键盘噪声）
- [x] **拼音约束解码**：Swift 拼音约束 beam 解码器（aime-llm/AimeLocalLLM，daemon+IME 已接入，超参已过 holdout）
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
