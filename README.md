# aime

AI 输入法：语音 + 拼音双模态，中英混输为核心场景，macOS native。规划见 [ROADMAP.md](ROADMAP.md)。

当前进度：**M1 — 语音输入 MVP**。菜单栏应用，按住快捷键说话，松开后本地转写（SpeechAnalyzer）→ LLM 精修 → 注入前台应用。

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

## 架构（M1）

```
Sources/aime/
├── App.swift                  MenuBarExtra + Settings scene
├── AppState.swift             会话状态机（idle→recording→transcribing→refining→done）
├── Settings.swift             UserDefaults 设置
├── Audio/AudioRecorder.swift  AVAudioEngine 采集 + 电平
├── ASR/TranscriberSession.swift  SpeechAnalyzer 流式转写（每次会话一个实例）
├── Refine/LLMRefiner.swift    OpenAI 兼容 chat/completions 精修
├── Context/ContextCapture.swift  AX 读取光标前文本 + 前台应用名
├── Inject/TextInjector.swift  粘贴（保存/恢复剪贴板）或模拟键入
├── Hotkey/HotkeyMonitor.swift 全局按住说话监听（NSEvent global monitor）
└── UI/                        浮层（NSPanel 非激活）+ 设置界面（SwiftUI）
```

## 隐私

- 语音转写完全在本地（Apple SpeechAnalyzer），音频不离开设备。
- 只有配置了 API Key 时，**转写文本**（及开启上下文时光标前的文本）才会发送到你自己配置的 endpoint；精修请求进行中浮层会显示"已读取上下文"指示。

## M1 已知取舍

- Silero VAD 未接入（按住说话模式下由用户控制起止，电平仅用于动画）；VAD 将在 M2 作为 Qwen3-ASR 的幻觉前置过滤引入。
- API Key 暂存 UserDefaults，M2 迁移 Keychain。
- Esc 取消键无法拦截，宿主应用也会收到 Esc。
