# 发布手册

> 分发方式：直接分发（DMG + GitHub Release）+ 公证，不走 App Store。
> 一条命令：`scripts/release.sh <版本号>`。本文记录一次性准备、发版步骤与欠账。
> CI 自动发布（tag 触发全流程）方案见 docs/ci-release.md。

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

## Sparkle 自动更新

- feed：`SUFeedURL` 固定指向 `releases/latest/download/appcast.xml`，每个 Release 都要把
  release.sh 产出的 `appcast.xml` 与 DMG 一起上传（`gh release create v<版本> <dmg> <appcast>`）；
- **EdDSA 私钥在登录钥匙串**（`generate_keys` 生成，条目名含 "Private key for signing Sparkle updates"）。
  **务必备份**（`generate_keys -x 文件` 导出）：丢失后无法向老用户推送可验签的更新；
- 换机发版：先 `generate_keys -f 文件` 导入私钥；
- appcast 在 staple 之后生成（staple 改 DMG 内容，签名按最终文件算），顺序不能颠倒。

## 开发机与正式安装版并存的坑

`make bundle` 出的 build/aime.app（开发证书）与 /Applications/Aime.app（Developer ID）
bundle id 相同，daemon 的 launchd 注册按 id 解析可能落到开发副本——签名与注册方不匹配
→ spawn 一直 EX_CONFIG（daemon 拉不起来，XPC ping 失败）。恢复：

```sh
rm -rf build/aime.app && /Applications/Aime.app/Contents/MacOS/aime --daemon-reregister
```

开发期在 build 目录迭代 daemon 时反过来同理：先移走 /Applications 副本或接受注册漂移。

## 已知事项与欠账

- **内嵌 IME 的公证票据**：只对外层 aime.app staple；用户点「安装输入法」拷出的 aime-ime.app
  依赖首次启用时在线查询票据（公证已覆盖其 hash）。完全离线首装场景不可用——可接受，
  若要消除需两段式公证（先单独公证 ime 再组装）。
- **LICENSE 未定**：仓库尚无 LICENSE 文件；发布页需注明词库来源（白霜拼音 rime-frost，GPL-3，
  运行时用户侧下载编译、不随包分发）。
- **发布前 checklist**（与流水线无关的质量项）：M4 实机走查（docs/M4-walkthrough.md）、
  翻译 v1 实机走查（docs/translate-v1.md）、主流应用兼容矩阵（浏览器/VS Code/微信/Terminal/Office）、
  真人录音 ASR 评测、8GB 机型基准。
- 系统要求 macOS 26+（SpeechAnalyzer 基线依赖），下载页需显著标注。
