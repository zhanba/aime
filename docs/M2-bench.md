# M2 评测结果（2026-07-11）

测试集：`testdata/testset.tsv` 50 句（纯中文 / 中英术语混说 / 专有名词 / 长句 / 数字），
音频由 `scripts/gen_testset.sh`（say/Tingting，16k 单声道）合成，共 211.2s。
指标：混合 CER（中文按字、英文/数字按连续段为词，忽略标点与大小写，Levenshtein）。

复现：`./scripts/gen_testset.sh && swift run -c release aime-bench --suite testdata [--backend <id>] [--vad]`

## 主对比（本机 Apple Silicon）

| 后端 | 混合 CER | 平均 RTF | 进程峰值内存 |
|---|---|---|---|
| SpeechAnalyzer（系统基线） | 8.98% | 0.020 | 7 MB¹ |
| Qwen3-ASR 0.6B 4-bit + VAD | **3.99%** | 0.032 | 2.9 GB |
| Qwen3-ASR 1.7B 8-bit + VAD | **1.55%** | 0.063 | 5.9 GB² |

¹ SpeechAnalyzer 的推理在系统服务进程中，本进程内存不反映真实占用。
² 含 MLX scratch 峰值；常驻稳态明显低于峰值（上游对 1.7B 有 4GB cache 上限保护）。

**结论：混说质量验收通过**——1.7B 错误率是系统基线的 1/5.8，0.6B 也有 2.3 倍优势。
差距主要来自英文术语：基线把 Docker→"的壳儿"、code review→"Coatreview"、bug→"buok"，
Qwen3 两档全部正确；基线还会做数字归一化（一千两百→1200），在严格字面 CER 下计为错误。

## 静音幻觉（W3 验收）

6s×5 段（纯静音×2、高斯白噪×2、50Hz 哼声×1）：

| 配置 | 幻觉输出 |
|---|---|
| Qwen3 0.6B 无 VAD | 2/5（静音与哼声各输出"嗯。"） |
| Qwen3 0.6B + Silero VAD 前置 | **0/5** ✅ |

## W4 置信度调研结论

speech-swift 的解码路径为纯 argMax 贪心，`generateText` 内部持有 logits 但公开 API 仅返回
String——**词级置信度被上游阻塞**。按计划不设为 M2 出口条件；`ASRResult.segments` 保留可选位，
M3 组合区低置信标记如需 Qwen 路径数据，选项：fork 暴露 per-token logprob / 提上游 PR。

## W5 daemon 验证记录

- `aime --daemon-status`：SMAppService 注册 `enabled`，launchd 按需拉起，XPC ping 返回版本与 pid ✅
- `aime --daemon-prepare` 连续两次：0.47s → **0.00s**（模型常驻 daemon，跨进程/重启不重载）✅
- 未覆盖：daemon 侧麦克风采集的真人链路（需用户为 aime-daemon 授予麦克风权限后实测）；
  XPC 连接方签名校验（TODO，M3 接 IME 进程前必须补）
- 默认关闭（设置 → 后台推理服务，实验性）；不可用时自动回退进程内运行

## 已知局限

- 测试音频为 TTS 合成音（干净、单一音色），CER 绝对值偏乐观；跨后端横向对比有效，
  真人录音测试集留待 M3 前补充。
- 下限机型（M1 Air 8GB）基准未跑（本机非目标下限），1.7B+8GB 建议实测后再定默认档策略。
