# 用稳定的开发证书签名，TCC 权限（麦克风/辅助功能）在重新构建后不会失效。
# 没有证书时改为 ad-hoc：make bundle SIGN_IDENTITY=-
# 正式发布：scripts/release.sh 以 Developer ID + --timestamp 调用本 Makefile
SIGN_IDENTITY ?= Apple Development
# 发布时传 CODESIGN_TS=--timestamp（需要网络，开发构建默认省略）
CODESIGN_TS ?=
# Hardened Runtime 常开：保持开发/发布行为一致（公证硬性要求）
CODESIGN := codesign --force --options runtime $(CODESIGN_TS) --sign "$(SIGN_IDENTITY)"
ENT := Resources/entitlements
APP := build/aime.app
IME_APP := build/aime-ime.app
BINARY := .build/release/aime
# MLX 的 Metal shader 库：纯 swift build 不会生成，需用 speech-swift 附带的脚本编译，
# 并放到可执行文件旁（MLX 运行时在可执行文件目录查找 mlx.metallib）
METALLIB_SCRIPT := .build/checkouts/qwen3-asr-swift/scripts/build_mlx_metallib.sh
METALLIB := .build/release/mlx.metallib
SPARKLE_FW := .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework
SPARKLE_IN_APP := $(APP)/Contents/Frameworks/Sparkle.framework
# 发布时由 scripts/release.sh 传入：VERSION=0.2.0 BUILD_NUM=123（默认保留 plist 里的值）
VERSION ?=
BUILD_NUM ?=
define stamp_version
	if [ -n "$(VERSION)" ]; then \
		/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(1); \
		[ -n "$(BUILD_NUM)" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUM)" $(1) || true; \
	fi
endef

.PHONY: build bundle ime install-ime run daemon-restart clean

build:
	swift build -c release
	BUILD_DIR=$(PWD)/.build bash $(METALLIB_SCRIPT) release

ime: build
	rm -rf $(IME_APP)
	mkdir -p $(IME_APP)/Contents/MacOS $(IME_APP)/Contents/Resources
	cp .build/release/aime-ime $(IME_APP)/Contents/MacOS/aime-ime
	cp Resources/ime-Info.plist $(IME_APP)/Contents/Info.plist
	cp Resources/aime-menu-icon.pdf Resources/aime-ime.icns $(IME_APP)/Contents/Resources/
	$(call stamp_version,$(IME_APP)/Contents/Info.plist)
	$(CODESIGN) --entitlements $(ENT)/ime.entitlements $(IME_APP)

# 主 app bundle：内嵌已签名的 aime-ime.app（Contents/Helpers，Apple 认可的嵌套代码位置），
# 应用内「安装输入法」从这里拷到 ~/Library/Input Methods——DMG 拖装即完整分发
bundle: build ime
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources $(APP)/Contents/Helpers $(APP)/Contents/Frameworks $(APP)/Contents/Library/LaunchAgents
	cp $(BINARY) $(APP)/Contents/MacOS/aime
	cp .build/release/aime-daemon $(APP)/Contents/MacOS/aime-daemon
	cp Resources/com.zhanba.aime.daemon.plist $(APP)/Contents/Library/LaunchAgents/
	# metallib 实体放 Resources（Contents/MacOS 只允许已签名的可执行体）；
	# MLX 在可执行文件同目录查找 mlx.metallib，用符号链接满足
	cp $(METALLIB) $(APP)/Contents/Resources/mlx.metallib
	ln -s ../Resources/mlx.metallib $(APP)/Contents/MacOS/mlx.metallib
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/aime-ime.icns Resources/aime-menu-glyph.pdf $(APP)/Contents/Resources/
	# 本地拼音 LLM 词元表（daemon 回退查 bundle Resources；换模型需重导，见 aime-llm）
	cp testdata/cjk_tokens.json $(APP)/Contents/Resources/
	$(call stamp_version,$(APP)/Contents/Info.plist)
	cp -R $(IME_APP) $(APP)/Contents/Helpers/
	# Sparkle：非 Xcode 构建需手动嵌入并逐个签名内嵌组件（官方 Sandboxing/非 Xcode 分发文档的顺序）
	cp -R $(SPARKLE_FW) $(APP)/Contents/Frameworks/
	$(CODESIGN) $(SPARKLE_IN_APP)/Versions/B/XPCServices/Installer.xpc
	codesign --force --options runtime $(CODESIGN_TS) --preserve-metadata=entitlements --sign "$(SIGN_IDENTITY)" $(SPARKLE_IN_APP)/Versions/B/XPCServices/Downloader.xpc
	$(CODESIGN) $(SPARKLE_IN_APP)/Versions/B/Autoupdate
	$(CODESIGN) $(SPARKLE_IN_APP)/Versions/B/Updater.app
	$(CODESIGN) $(SPARKLE_IN_APP)
	$(CODESIGN) --entitlements $(ENT)/daemon.entitlements $(APP)/Contents/MacOS/aime-daemon
	$(CODESIGN) --entitlements $(ENT)/aime.entitlements $(APP)

run: bundle
	open $(APP)

# 开发装法：拷入 ~/Library/Input Methods 并经 TIS 注册启用（分发版由 app 内按钮完成同样动作）
install-ime: bundle
	pkill -f "Input Methods/aime-ime.app" 2>/dev/null || true
	rm -rf "$(HOME)/Library/Input Methods/aime-ime.app"
	cp -R $(IME_APP) "$(HOME)/Library/Input Methods/"
	./build/aime.app/Contents/MacOS/aime --register-ime

# 重新构建后 launchd 里可能还跑着旧 daemon，用它强制重启
daemon-restart:
	launchctl kickstart -k gui/$$(id -u)/com.zhanba.aime.daemon 2>/dev/null || true

clean:
	rm -rf .build build
