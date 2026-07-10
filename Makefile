# 用稳定的开发证书签名，TCC 权限（麦克风/辅助功能）在重新构建后不会失效。
# 没有证书时改为 ad-hoc：make bundle SIGN_IDENTITY=-
SIGN_IDENTITY ?= Apple Development
APP := build/aime.app
BINARY := .build/release/aime
# MLX 的 Metal shader 库：纯 swift build 不会生成，需用 speech-swift 附带的脚本编译，
# 并放到可执行文件旁（MLX 运行时在可执行文件目录查找 mlx.metallib）
METALLIB_SCRIPT := .build/checkouts/qwen3-asr-swift/scripts/build_mlx_metallib.sh
METALLIB := .build/release/mlx.metallib

.PHONY: build bundle run clean

build:
	swift build -c release
	BUILD_DIR=$(PWD)/.build bash $(METALLIB_SCRIPT) release

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BINARY) $(APP)/Contents/MacOS/aime
	# metallib 实体放 Resources（Contents/MacOS 只允许已签名的可执行体）；
	# MLX 在可执行文件同目录查找 mlx.metallib，用符号链接满足
	cp $(METALLIB) $(APP)/Contents/Resources/mlx.metallib
	ln -s ../Resources/mlx.metallib $(APP)/Contents/MacOS/mlx.metallib
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign "$(SIGN_IDENTITY)" $(APP)

run: bundle
	open $(APP)

clean:
	rm -rf .build build
