# CI 自动发布方案

> 目标：`git tag v0.3.0 && git push origin v0.3.0` 之后无人值守——GitHub Actions 完成
> 构建、签名、公证、DMG、appcast、挂 Release 全流程。本地 `scripts/release.sh` 保留不动，
> CI 只是替你执行。手动流程见 docs/release.md（本文的前置阅读）。

## 版本管理原则

**git tag 是版本号的唯一事实来源。** 版本号不存在任何源码文件里（Makefile 构建时用
PlistBuddy 注入 `CFBundleShortVersionString`），build 号自动取 `git rev-list --count HEAD`——
所以没有「bump version」commit，也不存在 tag 与文件不一致的问题。

- 版本号规则：semver。0.x 阶段 minor 加功能（0.2.0 → 0.3.0）、patch 修 bug（0.3.0 → 0.3.1）。
- 发版动作 = 在 main 上打 tag 并 push，仅此而已。
- 这次算 minor 还是 patch 由人在打 tag 时判断，不上 conventional commits / release-please
  那套自动推导——个人项目不值得为此约束 commit 格式。

### 两条 CI 强制的约束

1. **tag 必须打在 main 上。** `CFBundleVersion` = main 的 commit 数，Sparkle 靠它判断
   「哪个版本更新」；从 feature 分支打 tag 会导致 build 号回退，Sparkle 拒绝推送该更新。
   workflow 里校验 `git merge-base --is-ancestor $GITHUB_SHA origin/main`。
2. **tag 名匹配 `v[0-9]+.[0-9]+.[0-9]+` 才触发**（workflow 的 `tags:` 过滤器），
   避免实验性 tag 误触发正式发布。

### 回滚

某版本出问题时，把上一版内容以**新版本号**重发（如 v0.3.2 = v0.3.1 的代码 revert 后重新发版）。
不能删 release 让 `latest` 回退——build 号必须前进，老用户的 Sparkle 不会「降级」。

## 需要搬进 GitHub Actions Secrets 的三份凭据

目前都在本地钥匙串，是 CI 化的全部前置工作：

| Secret | 来源 | CI 里的用法 |
|---|---|---|
| `DEVELOPER_ID_P12`、`P12_PASSWORD` | 钥匙串导出 Developer ID Application 证书为 .p12，`base64 -i cert.p12` | `security import` 进临时钥匙串 |
| `APPLE_ID`、`TEAM_ID`、`NOTARY_PASSWORD` | 本地 `store-credentials` 用的同一套（app 专用密码） | CI 现场 `xcrun notarytool store-credentials aime-notary`，release.sh 零改动 |
| `SPARKLE_ED_KEY` | `generate_keys -x 文件` 导出的私钥（正好完成 release.md 里「务必备份」的欠账） | 写临时文件，传 `generate_appcast --ed-key-file` |

公证凭据以后可换成 App Store Connect API Key（`notarytool --key`）：可撤销、不绑个人
Apple ID，更适合 CI，但非必须。

## release.sh 的唯一改动

`generate_appcast` 默认从**登录钥匙串**读 EdDSA 私钥，CI 的临时钥匙串里没有。
加环境变量分支，本地不设时行为不变：

```sh
ED_KEY_ARGS=()
[[ -n "${SPARKLE_ED_KEY_FILE:-}" ]] && ED_KEY_ARGS=(--ed-key-file "${SPARKLE_ED_KEY_FILE}")
.build/artifacts/sparkle/Sparkle/bin/generate_appcast "${ED_KEY_ARGS[@]}" \
    --download-url-prefix ... -o "${DIST}/appcast.xml" "${DIST}"
```

## Workflow：`.github/workflows/release.yml`

```yaml
name: release
on:
  push:
    tags: ['v[0-9]+.[0-9]+.[0-9]+']

jobs:
  release:
    runs-on: macos-26          # 需要 macOS 26 SDK（Package.swift: .macOS("26.0")）
    permissions:
      contents: write          # gh release create 用
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0       # 关键！build 号 = git rev-list --count HEAD，浅克隆会算错

      - name: 校验 tag 在 main 上
        run: |
          git fetch origin main
          git merge-base --is-ancestor "$GITHUB_SHA" origin/main \
            || { echo "tag 必须打在 main 上（build 号单调性依赖 main 的 commit 数）"; exit 1; }

      - name: 选择 Xcode 26
        run: sudo xcode-select -s /Applications/Xcode_26.app

      - name: 导入签名证书（临时钥匙串）
        env:
          P12: ${{ secrets.DEVELOPER_ID_P12 }}
          P12_PASSWORD: ${{ secrets.P12_PASSWORD }}
        run: |
          KEYCHAIN=$RUNNER_TEMP/build.keychain
          security create-keychain -p ci "$KEYCHAIN"
          security default-keychain -s "$KEYCHAIN"
          security unlock-keychain -p ci "$KEYCHAIN"
          echo "$P12" | base64 -d > "$RUNNER_TEMP/cert.p12"
          security import "$RUNNER_TEMP/cert.p12" -k "$KEYCHAIN" \
            -P "$P12_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple: -s -k ci "$KEYCHAIN"

      - name: 配置公证凭据
        run: |
          xcrun notarytool store-credentials aime-notary \
            --apple-id "${{ secrets.APPLE_ID }}" \
            --team-id "${{ secrets.TEAM_ID }}" \
            --password "${{ secrets.NOTARY_PASSWORD }}"

      - name: 测试
        run: swift test

      - name: 构建 + 签名 + 公证 + appcast
        env:
          SPARKLE_ED_KEY: ${{ secrets.SPARKLE_ED_KEY }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          echo "$SPARKLE_ED_KEY" > "$RUNNER_TEMP/sparkle_ed_key"
          SPARKLE_ED_KEY_FILE="$RUNNER_TEMP/sparkle_ed_key" scripts/release.sh "$VERSION"

      - name: 发布 GitHub Release
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          VERSION="${GITHUB_REF_NAME#v}"
          gh release create "$GITHUB_REF_NAME" \
            "build/dist/Aime-${VERSION}.dmg" build/dist/appcast.xml \
            --title "Aime ${VERSION}" --generate-notes
```

## Release notes

起步用 `--generate-notes`（按两个 tag 间的 PR/commit 自动列变更，中文 commit message
可读性足够），发完在 GitHub 网页上润色。

## 日常发版操作（落地后）

```sh
# main 上功能合并完毕
git tag v0.3.0 && git push origin v0.3.0
# 等 CI 绿 → 网页上润色 release notes → 完事
```

失败重试：公证偶发排队慢或超时，workflow 失败直接 re-run，脚本幂等。

## 已知事项与待确认

- **runner 镜像**：确认 GitHub 托管 runner 的 `macos-26` 镜像是否可用、带哪个 Xcode
  （查 [actions/runner-images](https://github.com/actions/runner-images)）。若尚未提供，
  过渡方案是自托管 runner（自己的 Mac 挂常驻 runner，凭据可继续用本地钥匙串，改动最小）。
- **计费**：macOS runner 分钟数按 Linux 10 倍计费，但公开仓库免费——本仓库不受影响。
- **appcast 只含当前版本**：`generate_appcast` 只扫 build/dist 里这一个 DMG，与手动流程
  一致（`latest/download` 重定向兜底）；以后想让 appcast 保留历史版本再改。
- **可选进阶**：
  - Sparkle 更新弹窗显示变更内容：`generate_appcast --link` 或同名 `.html` 挂 release notes；
  - beta 通道：`v0.4.0-beta.1` tag → `gh release --prerelease` + Sparkle 2 channel，
    GitHub 的 `latest` 不指向 prerelease，正式用户 feed 不受影响。
