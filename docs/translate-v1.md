# 翻译 v1：组合区 Tab 中→英

> 定位：翻译是组合区的一次**可逆预览变换**，不是新的输入路径。复用候选栏、Esc/回改、
> LLM 通道（PinyinLLMConfig 同一配置）、隐私门控（pureLocalMode / 屏蔽列表）。

## 交互

```
输入 nihao,zuijinzenmeyang     组合区: 拼音/预览          候选栏: [AI]你好，最近怎么样 …
按 Tab                         组合区尾部: ⇢ ⋯            候选栏角落: 翻译中…
翻译返回                       组合区: Hi, how have you been?（实线）
                               候选栏: 1[译]Hi, how have you been?  2[译]备选译法  3[原]你好，最近怎么样
Space/Enter/数字               上屏所选（英文上屏不入用户词库，避免 the/have 污染热词）
Tab / Esc / 退格               退回中文组合态，源中文与候选完好
```

## 状态机（AimeInputController）

`translationPhase: none / pending / shown`，翻译源 = `confirmedText + currentPreview`
（整个组合内容，含语音段——语音说中文、Tab 出英文免费得到）。

按键语义（`handleTranslationKey`，翻译态优先分发，`nil` = 交回正常路径）：

| 按键 | pending | shown |
|---|---|---|
| Tab / Esc / 退格 | 取消，回中文态 | 回中文态 |
| Enter | 取消翻译，提交中文原义 | 提交高亮译文 |
| Space / 方向 / 数字 | 取消翻译，作用于中文候选 | 作用于译文候选（左右键时组合区跟随高亮） |
| 字母 | 取消翻译，照常进 rawBuffer | 同左（退出翻译态继续打字） |
| 映射标点 | 取消翻译，中文语义提交 | 提交高亮译文 + ASCII 标点（选[原]则全角） |
| 右 Option（语音） | 清除翻译态再录音 | 同左 |

其他要点：
- 翻译请求 12s 超时，失败 → 候选栏提示"翻译失败，Tab 重试"，中文态无损恢复；
- pending 期间到达的拼音 LLM 转换只存结果不动 UI（避免打断译文候选浏览）；
- 上屏译文后 Shift+Space 回改恢复的是**中文组合态**（源始终保留），可换候选或再 Tab；
- prompt 带光标前文（对话上文对齐语气/称呼/用词）；translationSource 在 Tab 时刻冻结。

Tab 原本与 ↓ 冗余绑定翻页，本次让给翻译（翻页仍有 ↑↓）；Tab 也是国内主流输入法的
翻译触发键。

## 实现

- `Sources/AimePinyin/Translator.swift` — OpenAI 兼容中→英，两行输出（首选+备选），
  剥包裹引号；解析有单测（TranslatorTests）。
- `Sources/aime-ime/AimeInputController.swift` — 翻译态状态机 + 候选 Kind
  `.translation("译") / .translationSource("原")` + 组合区渲染 + `barHint`（候选栏
  pageInfo 槽复用为临时提示：翻译中/失败/不可用）。

## 留到 v1.5 / 欠账

- 持续翻译模式（Shift+Tab 切换，提交时自动进翻译态，两段式确认）——等 v1 手感验证；
- streaming 译文逐词出现（体感延迟减半）；
- 翻译态状态机在 IME target 内无单测（IMK 依赖），依赖实机走查；
- 实机走查清单：Tab 触发/回退、pending 中打字、混合语音段翻译、失败提示、
  屏蔽应用内 Tab 提示、译文上屏后回改。
