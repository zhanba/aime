# 发布手册

> 分发方式：直接分发（DMG + GitHub Release）+ 公证，不走 App Store。
> 一条命令：`scripts/release.sh <版本号>`。本文记录一次性准备、发版步骤与欠账。

## 一次性准备

### 1. Developer ID Application 证书

当前钥匙串里只有 `Apple Development` 开发证书（免费账号）。分发给他人需要：

1. 加入 [Apple Developer Program](https://developer.apple.com/programs/)（99 USD/年）；
2. Xcode → Settings → Accounts → 选中团队 → Manage Certificates → `+` → **Developer ID Application**
   （或在 developer.apple.com → Certificates 手动创建后双击导入钥匙串）；
3. 验证：`security find-identity -v -p codesigning` 应出现 `Developer ID Application: <名字> (<TEAMID>)`。

### 2. notarytool 凭据（存入钥匙串，脚本引用 profile 名 `aime-notary`）

1. [appleid.apple.com](https://appleid.apple.com) → 登录与安全 → App 专用密码 → 生成一个；
2. ```sh
   xcrun notarytool store-credentials aime-notary \
     --apple-id <你的AppleID邮箱> --team-id <TEAMID> --password <app专用密码>
   ```

## 发版步骤

```sh
# 1. 确保工作区干净、测试通过
swift test

# 2. 完整发布（构建 → 签名 → 公证 app → DMG → 公证 DMG → staple → 终验）
scripts/release.sh 0.2.0

# 3. 打 tag、发 GitHub Release，把 build/dist/Aime-0.2.0.dmg 传上去
git tag v0.2.0 && git push --tags
gh release create v0.2.0 build/dist/Aime-0.2.0.dmg --title "Aime 0.2.0" --notes "..."
```

- 版本号是唯一参数；build 号自动取 `git rev-list --count HEAD`（可回溯到 commit）。
- 没有 Developer ID 时本地演练：`SIGN_IDENTITY="Apple Development" scripts/release.sh 0.2.0 --skip-notarize`。
- 公证一般 1–5 分钟；失败时 `xcrun notarytool log <submission-id> --keychain-profile aime-notary` 看原因。

## 用户侧安装体验（设计现状）

1. 挂载 DMG，拖 Aime.app 到 Applications；
2. 首次打开 app（Gatekeeper 放行，因已公证+staple）；
3. 设置 → 拼音页 → 「安装输入法」按钮：把内嵌的 `Contents/Helpers/aime-ime.app`
   拷到 `~/Library/Input Methods` 并 TIS 注册启用（`IMEInstaller`）；
4. 系统设置里添加「Aime拼音」；麦克风/辅助功能权限在首次使用时按需弹出。

## 签名结构

| 组件 | entitlements | 说明 |
|---|---|---|
| aime.app | `audio-input` | daemon 不可用时进程内 ASR 回退需要麦克风 |
| aime-daemon | `audio-input` | 音频采集主路径 |
| aime-ime.app | 无 | IMKit 进程不申请敏感权限 |

- 全部 Hardened Runtime（`--options runtime`），开发/发布一致（Makefile `CODESIGN` 变量）。
- daemon XPC 以 audit token + `SecRequirement`（Apple 锚 + 同 Team ID）校验连接方，
  ad-hoc 构建（无 Team ID）降级为同 UID 放行。

## 已知事项与欠账

- **Sparkle 自动更新未接入**（ROADMAP 既定方向）。接入前需决策：appcast.xml 托管位置
  （GitHub Releases/Pages 均可）；需生成 EdDSA 密钥对、在 Info.plist 写 `SUFeedURL`/`SUPublicEDKey`、
  release.sh 追加 `generate_appcast` 步骤。首个公开版本若不带 Sparkle，则老用户需手动升级一次。
- **内嵌 IME 的公证票据**：只对外层 aime.app staple；用户点「安装输入法」拷出的 aime-ime.app
  依赖首次启用时在线查询票据（公证已覆盖其 hash）。完全离线首装场景不可用——可接受，
  若要消除需两段式公证（先单独公证 ime 再组装）。
- **LICENSE 未定**：仓库尚无 LICENSE 文件；发布页需注明词库来源（白霜拼音 rime-frost，GPL-3，
  运行时用户侧下载编译、不随包分发）。
- **发布前 checklist**（与流水线无关的质量项）：M4 实机走查（docs/M4-walkthrough.md）、
  翻译 v1 实机走查（docs/translate-v1.md）、主流应用兼容矩阵（浏览器/VS Code/微信/Terminal/Office）、
  真人录音 ASR 评测、8GB 机型基准。
- 系统要求 macOS 26+（SpeechAnalyzer 基线依赖），下载页需显著标注。
