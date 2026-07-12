#!/bin/bash
# aime 发布脚本：版本注入 → Developer ID 签名构建 → 严格校验 → 公证 app →
# 制作 DMG → 公证 DMG → staple → Gatekeeper 终验。
#
# 前置（一次性，详见 docs/release.md）：
#   1. Apple Developer Program 会员 + Developer ID Application 证书装入钥匙串
#   2. xcrun notarytool store-credentials aime-notary --apple-id <id> --team-id <team> --password <app专用密码>
#
# 用法：
#   scripts/release.sh 0.2.0                 # 完整发布
#   scripts/release.sh 0.2.0 --skip-notarize # 本地演练（可用开发证书：SIGN_IDENTITY="Apple Development"）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
if [[ -z ${VERSION} ]]; then
    echo "用法: scripts/release.sh <版本号> [--skip-notarize]" >&2
    exit 1
fi
SKIP_NOTARIZE=false
[[ "${2:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=true

IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
PROFILE="${NOTARY_PROFILE:-aime-notary}"
# build 号用主干提交数，单调递增且可回溯到 commit
BUILD_NUM=$(git rev-list --count HEAD)
DIST=build/dist
DMG="${DIST}/Aime-${VERSION}.dmg"

if ! security find-identity -v -p codesigning | grep -q "${IDENTITY}"; then
    echo "错误：钥匙串里没有「${IDENTITY}」证书。" >&2
    echo "正式发布需要 Developer ID Application 证书（docs/release.md 有申请步骤）；" >&2
    echo "本地演练可用：SIGN_IDENTITY=\"Apple Development\" scripts/release.sh ${VERSION} --skip-notarize" >&2
    exit 1
fi

if [[ -n $(git status --porcelain) ]]; then
    echo "警告：工作区有未提交改动，发布产物将无法精确回溯到 commit。"
fi

echo "==> [1/6] 构建 + 签名（${IDENTITY}, hardened runtime, v${VERSION} build ${BUILD_NUM}）"
make bundle SIGN_IDENTITY="${IDENTITY}" CODESIGN_TS=--timestamp VERSION="${VERSION}" BUILD_NUM="${BUILD_NUM}"

echo "==> [2/6] 签名严格校验"
codesign --verify --strict --deep --verbose=2 build/aime.app
codesign --verify --strict --verbose=2 build/aime.app/Contents/Helpers/aime-ime.app

rm -rf "${DIST}"
mkdir -p "${DIST}"

if ! ${SKIP_NOTARIZE}; then
    echo "==> [3/6] 公证 app（notarytool profile: ${PROFILE}）"
    ditto -c -k --keepParent build/aime.app "${DIST}/aime-app.zip"
    xcrun notarytool submit "${DIST}/aime-app.zip" --keychain-profile "${PROFILE}" --wait
    xcrun stapler staple build/aime.app
    rm "${DIST}/aime-app.zip"
else
    echo "==> [3/6] 跳过 app 公证（--skip-notarize）"
fi

echo "==> [4/6] 制作 DMG"
STAGING=$(mktemp -d)
cp -R build/aime.app "${STAGING}/Aime.app"
ln -s /Applications "${STAGING}/Applications"
hdiutil create -volname "Aime ${VERSION}" -srcfolder "${STAGING}" -ov -format UDZO "${DMG}"
rm -rf "${STAGING}"
codesign --force --sign "${IDENTITY}" $([[ ${SKIP_NOTARIZE} == false ]] && echo --timestamp) "${DMG}"

if ! ${SKIP_NOTARIZE}; then
    echo "==> [5/6] 公证 DMG + staple"
    xcrun notarytool submit "${DMG}" --keychain-profile "${PROFILE}" --wait
    xcrun stapler staple "${DMG}"

    echo "==> [6/6] Gatekeeper 终验"
    spctl --assess --type exec --verbose=2 build/aime.app
    spctl --assess --type open --context context:primary-signature --verbose=2 "${DMG}" || true
else
    echo "==> [5/6][6/6] 跳过 DMG 公证与 Gatekeeper 终验（--skip-notarize）"
fi

# appcast 必须在 staple 之后生成（staple 会改 DMG 内容，EdDSA 签名按最终文件算）。
# 私钥在登录钥匙串（generate_keys 生成）；appcast.xml 与 DMG 一起挂上 GitHub Release，
# SUFeedURL 固定指向 releases/latest/download/appcast.xml。
echo "==> 生成 Sparkle appcast"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --download-url-prefix "https://github.com/zhanba/aime/releases/download/v${VERSION}/" \
    -o "${DIST}/appcast.xml" "${DIST}"

echo
echo "完成：${DMG} + ${DIST}/appcast.xml（v${VERSION} build ${BUILD_NUM}）"
echo "发布：git tag v${VERSION} && git push --tags"
echo "      gh release create v${VERSION} ${DMG} ${DIST}/appcast.xml --title \"Aime ${VERSION}\""
