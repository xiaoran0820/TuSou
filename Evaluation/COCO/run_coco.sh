#!/bin/sh
# COCO 2017 验证集评测：编译评测程序 → 建索引（中断后可续跑）→ 测模型本身 → 生成中文查询 → 测 App 整体。
# 需要：COCO 数据（val2017/ 和 annotations/）在 $COCO，默认是工程上一级的 datasets/coco2017；
#       ImageSearch/MLModels 里有 MobileCLIP-S2；phrases_zh.tsv 是人工写好的中文短语。
set -e
cd "$(dirname "$0")/../.."
COCO="${COCO:-../datasets/coco2017}"
OUT="${TMPDIR:-/tmp}/tusou-coco"
mkdir -p "$OUT"
for m in mobileclip_s2_image mobileclip_s2_text; do
  [ -d "$OUT/$m.mlmodelc" ] || xcrun coremlcompiler compile "ImageSearch/MLModels/$m.mlpackage" "$OUT" >/dev/null
done
swiftc -O -lsqlite3 -o "$OUT/evaluate" ImageSearch/Models/ImageRecord.swift ImageSearch/Search/*.swift \
  ImageSearch/Indexing/ImageAnalyzer.swift ImageSearch/Indexing/MobileCLIP.swift ImageSearch/Indexing/IndexStore.swift \
  Evaluation/COCO/main.swift
"$OUT/evaluate" index "$COCO/val2017" "$COCO/index.sqlite" "$OUT" ImageSearch/Resources
"$OUT/evaluate" model "$COCO/index.sqlite" "$COCO/annotations/captions_val2017.json" "$OUT" ImageSearch/Resources \
  Evaluation/COCO/results_model.json
python3 Evaluation/COCO/make_queries.py "$COCO/annotations/instances_val2017.json" \
  "$COCO/annotations/captions_val2017.json" Evaluation/COCO
"$OUT/evaluate" app "$COCO/index.sqlite" "$COCO/annotations/instances_val2017.json" Evaluation/COCO/queries_zh.json \
  Evaluation/COCO/phrases_zh.tsv "$OUT" ImageSearch/Resources Evaluation/COCO/results_app.json
# 同样的查询，按 App 开着「整句翻译中文查询」时的方式再测一遍（译文表由 Evaluation/translate 用系统翻译生成）
"$OUT/evaluate" app "$COCO/index.sqlite" "$COCO/annotations/instances_val2017.json" Evaluation/COCO/queries_zh.json \
  Evaluation/COCO/phrases_zh.tsv "$OUT" ImageSearch/Resources Evaluation/COCO/results_app_translated.json \
  Evaluation/translations.tsv
