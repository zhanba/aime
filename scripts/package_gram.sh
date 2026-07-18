#!/bin/zsh
# 语法模型发布打包：LMDG .gram → 剪枝 gram.bin → raw deflate → GitHub Release
#
# 数据来源：万象拼音 LMDG（https://github.com/amzxyz/RIME-LMDG，CC-BY-4.0，作者 amzxyz）。
# 剪枝策略（2026-07 evaluated，见 docs/algorithm.md）：3 字搭配全保留（泛化层），
# ≥4 字要求 log(频)×10000 ≥ 175000（特化层）。560 句评测：句准 50.0%（基线 39.5%，全量 52.3%）。
#
# 用法：scripts/package_gram.sh [工作目录=/tmp/aime-gram-release]
set -euo pipefail

WORK="${1:-/tmp/aime-gram-release}"
LMDG_URL="https://github.com/amzxyz/RIME-LMDG/releases/download/LTS/wanxiang-lts-zh-hans.gram"
LMDG_SIZE=420012076  # LTS 2025-12-07；上游更新后需同步改
MIN_LOG_LONG=175000

mkdir -p "$WORK"
cd "$(dirname "$0")/.."

echo "==> 下载 LMDG（约 400MB，支持断点续传）"
while [ "$(stat -f%z "$WORK/wanxiang.gram" 2>/dev/null || echo 0)" -ne "$LMDG_SIZE" ]; do
    curl -L -C - -o "$WORK/wanxiang.gram" "$LMDG_URL" || sleep 2
done

echo "==> 编译 aime-gram 并转换（剪枝 --min-log-long $MIN_LOG_LONG）"
swift build -c release --product aime-gram
.build/release/aime-gram convert "$WORK/wanxiang.gram" \
    --min-log-long "$MIN_LOG_LONG" --out "$WORK/gram.bin"

echo "==> raw deflate 压缩（GramInstaller 用系统 Compression 解压）"
python3 - "$WORK/gram.bin" "$WORK/gram.bin.z" <<'PY'
import sys, zlib
src, dst = sys.argv[1], sys.argv[2]
compressor = zlib.compressobj(6, zlib.DEFLATED, -15)  # wbits=-15: raw deflate
with open(src, "rb") as f, open(dst, "wb") as out:
    while chunk := f.read(1 << 22):
        out.write(compressor.compress(chunk))
    out.write(compressor.flush())
PY
ls -lh "$WORK/gram.bin" "$WORK/gram.bin.z"

cat <<EOF

发布（需要 gh 已登录）：
  gh release create gram-v1 "$WORK/gram.bin.z" \\
    --title "语法模型 v1（万象 LMDG 剪枝版）" \\
    --notes "数据来自万象拼音 LMDG 语法模型（CC-BY-4.0，作者 amzxyz，https://github.com/amzxyz/RIME-LMDG），由 aime-gram 剪枝转换。3 字搭配全保留，≥4 字取 log 频 ≥ 17.5。"
EOF
