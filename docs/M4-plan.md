# M4 实施方案：双模态融合（待评审）

> 目标：语音进 composition、回改键、跨模态纠错、共享词库双向增强、隐私面板。
> 验收三场景：纯拼音盲打 / 语音长段听写+回改修正 / "打字+按住说话+继续打字"一次提交。

## 0. 核心架构决策（先定这四个）

### 决策 A：语音怎么进 IME —— IME 直连 daemon

语音要进 composition，音频/模型在 daemon，composition 在 aime-ime 进程。两条路：
app 中转（app 收热键→daemon→app→??→IME，无现成通道）或 **IME 直连 daemon**（IME 作为
XPC 客户端，daemon 采音并流式回传 transcript——现有 `AimeDaemonXPC` 协议原样可用）。

选后者。配套改动：
- `DaemonClient`/代理层从 app target 移入 AimeASR 共享库（IME 复用）；
- **XPC 连接方签名校验**（M3 遗留欠账）此时必须补：daemon 的
  `shouldAcceptNewConnection` 校验同 Team ID——IME 接入前的安全前提；
- IME 语音依赖 daemon：daemon 不可用时组合区提示"后台服务未启用（设置→高级）"，
  不在 IME 进程内跑 MLX（避免输入法进程背 2GB 模型）。daemon 从"实验性"转正。

### 决策 B：热键归属 —— 按当前输入法分流

右 Option 按住说话现在由 app 全局监听。M4 起：
- **aime拼音是当前输入法** → IME 自己处理（`recognizedEvents` 加 flagsChanged），
  语音进 composition；app 侧检测到当前输入源是 aime 时跳过（TIS 查询），避免双触发；
- 其他输入法激活 → 维持现状（app 浮层 + 粘贴注入）。

### 决策 C：composition 数据模型 —— 确认栈自然扩展

不引入全新片段结构，扩展现有 `confirmedStack`：

```swift
confirmedStack: [(text: String, keys: String?, source: .pinyin | .voice)]
// keys=nil 表示语音段（退格=整段删除，无按键可恢复）
rawBuffer: String   // 唯一活动元素：拼音 buffer 或（录音时）语音流式占位
```

"打字+说话+打字"流程：拼音组合中按下热键 → **当前预览自动确认入栈** →
语音流式文本显示为临时段 → 松开+定稿 → 语音文本入栈（source=voice）→
继续打拼音 → 空格一次性上屏全部。Esc 录音中=只取消语音段；非录音=全弃。

### 决策 D：语音消歧不需要模式切换 —— 回验器自动分流

组合中按住说话有两种意图：追加新内容 vs 把待定拼音"说一遍"消歧。不做手势区分，
**用 PinyinVerifier 自动判断**：ASR 结果若与当前拼音 buffer 音节匹配（pass/demote）
→ 是消歧，直接替换预览（声调信息补全了无声调拼音）；不匹配 → 是新内容，走决策 C
的追加流程。一个手势，机械分流，无需用户学习。

## 1. 工作分解

### P1 基础设施（先行，其余全依赖它）
- DaemonClient/XPCProxy 移入 AimeASR；daemon `shouldAcceptNewConnection`
  校验连接方 audit token 的签名 Team ID；
- IME 启动时 ping daemon 并缓存可用性；app 侧 TIS 检测当前输入源分流热键。

### P2 语音入 composition
- IME `recognizedEvents` |= flagsChanged，右 Option 按住/松开状态机；
- 录音中：候选条切换为 🎤 状态（电平 + 流式 transcript）；组合区临时段点线显示；
- 定稿入栈（source=voice），继续拼音输入；
- 语音段的 LLM 精修：v1 不做（Qwen3 直出质量已够，留 M4.5），标注在文档。

### P3 语音消歧（决策 D 的实现）
- rawBuffer 非空时的 ASR 定稿 → verify(候选=ASR文本, segments=当前切分)；
- pass/demote → 替换预览并标记高置信（实线）；reject → 追加为语音段。

### P4 回改键（仅 IME 提交，v1）
- 每次 commit 记录 {text, 时间戳, 提交后光标位}; 
- **Shift+Space**（非组合态）触发回改：守卫=10s 内 && 光标未移动；
  用 `insertText("", replacementRange:)` 删掉刚上屏文本，恢复组合态；
- 拼音提交的回改：恢复原 confirmedStack+rawBuffer（候选条重现，换个候选就走）；
- **语音提交的回改 = 跨模态纠错 v1**：语音文本经 `PinyinVerifier.readings`
  反推拼音 → 生成伪拼音 buffer → 整套拼音机器（切分/词候选/逐段确认/LLM）直接可用，
  prompt 附注"原语音识别为 X"。限纯中文语音段；含英文则退化为删除重打。
- app 浮层流程（非 IME）的回改不做（跨应用注入位置不可控），文档注明。

### P5 共享词库双向增强
- UserDictionary：mtime 热重载（同词库方案）+ 时间衰减评分
  `score = count · exp(−天数/30)`（借鉴 RIME tick 衰减的简化版）；
- 拼音→语音：voice 会话的 contextHint = 光标前文 + `topEntries()`（ASR 热词，
  Qwen3 context 槽已验证）；app 与 IME 两条语音路径都接；
- 语音→拼音：语音上屏文本走同一 `learn()`（source="voice"），抽词入库；
- 设置中心"教它"页：词条列表（词/来源/次数/最近用）+ 删除 + 手动添加。

### P6 隐私面板
- 共享配置新增：`privacyBlockedApps: [String]`（bundle id）、`pureLocalMode: Bool`；
- IME 经 `client().bundleIdentifier()`、app 经 frontmostApplication 判定：
  屏蔽列表内 → 不读上下文、不发 LLM（拼音退纯本地，语音只出 ASR 原文）；
- 纯本地模式一键开关：全局禁 LLM 调用；
- 设置页：应用矩阵（添加/移除）+ 数据流向说明文案。

### P7 验收与测试
- 状态机单测：确认栈混合来源、录音中 Esc、消歧分流（verifier 门控）、回改守卫；
- 三场景人工走查清单（需要你实测：语音手感、各应用兼容性我无法无头验证）；
- 评测补充：消歧正确率小集（10 组"歧义拼音+语音"）——需真人录音，可先记欠账。

## 2. 顺序与依赖

P1 → P2 → P3（P2 的自然延伸）→ P4（独立，可并行）→ P5/P6（独立）→ P7。
P2 是最大件（IME 状态机 + 候选条录音态 + XPC 流式接线）。

## 3. 风险

| 风险 | 应对 |
|---|---|
| IMK 的 flagsChanged 在部分宿主不可靠 | 早测应用矩阵；不可靠时回退 app 中转（Plan B：app 监听热键，经 daemon 单播给 IME 的活动连接） |
| 回改的 `insertText(replacementRange:)` 各应用行为不一 | 守卫严格（10s+光标未动）+ 失败静默放弃；应用矩阵实测 |
| daemon 麦克风权限首次弹窗时机（正在打字时弹） | 设置页"启用语音输入"引导页主动触发授权，避免打断输入 |
| 反推拼音的多音字错误污染跨模态纠错 | verifier 的多音字表复用；错了也只是候选不优，原文永远在候选栏 |
| Shift+Space 与宿主/其他输入法习惯冲突 | 可配置化放 M4.5；先固定并在设置页注明 |
