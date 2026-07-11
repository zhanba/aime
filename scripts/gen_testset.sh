#!/bin/bash
# 从 testdata/testset.tsv 合成测试音频（say/Tingting → 16k 单声道 wav）。
# 音频不入库（.gitignore），本地跑一次即可。
# 局限：TTS 合成音偏干净，CER 绝对值会偏乐观，横向对比后端仍有效。
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=testdata/audio
mkdir -p "$OUT"
while IFS=$'\t' read -r id text; do
  [ -z "$id" ] && continue
  if [ ! -f "$OUT/$id.wav" ]; then
    say -v Tingting -o "$OUT/$id.aiff" "$text"
    afconvert -f WAVE -d LEI16@16000 -c 1 "$OUT/$id.aiff" "$OUT/$id.wav"
    rm "$OUT/$id.aiff"
    echo "$id ok"
  fi
done < testdata/testset.tsv
echo "done: $(ls "$OUT"/*.wav | wc -l | tr -d ' ') 条音频"
