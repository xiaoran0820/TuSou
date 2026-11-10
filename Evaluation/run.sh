#!/bin/sh
# 在 Mac 上编译并运行检索效果评测（用 App 的同一套识别和检索代码）。
# 需要先运行 fetch_images.py 下载评测图片，并且 ImageSearch/MLModels 里有 MobileCLIP-S2 模型。
set -e
cd "$(dirname "$0")/.."
OUT="${TMPDIR:-/tmp}/tusou-eval"
mkdir -p "$OUT"
for m in mobileclip_s2_image mobileclip_s2_text; do
  xcrun coremlcompiler compile "ImageSearch/MLModels/$m.mlpackage" "$OUT" >/dev/null
done
swiftc -O -o "$OUT/evaluate" \
  ImageSearch/Models/ImageRecord.swift ImageSearch/Search/*.swift \
  ImageSearch/Indexing/ImageAnalyzer.swift ImageSearch/Indexing/MobileCLIP.swift \
  Evaluation/main.swift
"$OUT/evaluate" Evaluation/images Evaluation/queries.json "$OUT" ImageSearch/Resources Evaluation/results.json
