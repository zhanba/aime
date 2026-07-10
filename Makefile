# 用稳定的开发证书签名，TCC 权限（麦克风/辅助功能）在重新构建后不会失效。
# 没有证书时改为 ad-hoc：make bundle SIGN_IDENTITY=-
SIGN_IDENTITY ?= Apple Development
APP := build/aime.app
BINARY := .build/release/aime

.PHONY: build bundle run clean

build:
	swift build -c release

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp $(BINARY) $(APP)/Contents/MacOS/aime
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)

run: bundle
	open $(APP)

clean:
	rm -rf .build build
