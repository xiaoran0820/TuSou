#!/usr/bin/env python3
"""生成 COCO 评测用的中文查询和待改写的描述样本。

用法：python3 make_queries.py <instances_val2017.json> <captions_val2017.json> <输出目录>
- queries_zh.json：80 类物体各一个中文查询（categories_zh.json），加上同时出现最多的 30 组两类物体组合
  （两类物体在同一张图里都占画面 1% 以上，至少 15 张）。
- phrases_sample.tsv：固定随机种子抽 300 张图，每张取一条人工英文描述，供改写成中文搜索短语。
"""
import json
import os
import random
import sys
from collections import Counter
from itertools import combinations

inst = json.load(open(sys.argv[1]))
caps = json.load(open(sys.argv[2]))
out = sys.argv[3]
zh = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "categories_zh.json"), encoding="utf-8"))

name = {c["id"]: c["name"] for c in inst["categories"]}
area = {im["id"]: im["width"] * im["height"] for im in inst["images"]}
salient = {}
for a in inst["annotations"]:
    if a["area"] / area[a["image_id"]] >= 0.01:
        salient.setdefault(a["image_id"], set()).add(name[a["category_id"]])

pairs = Counter()
for cats in salient.values():
    for p in combinations(sorted(cats), 2):
        pairs[p] += 1
top_pairs = [p for p, n in pairs.most_common() if n >= 15][:30]

queries = [{"query": zh[c["name"]], "categories": [c["name"]]} for c in inst["categories"]]
queries += [{"query": f"{zh[a]} {zh[b]}", "categories": [a, b]} for a, b in top_pairs]
with open(os.path.join(out, "queries_zh.json"), "w", encoding="utf-8") as f:
    json.dump(queries, f, ensure_ascii=False, indent=1)

by_image = {}
for a in caps["annotations"]:
    by_image.setdefault(a["image_id"], []).append(a["caption"].strip().replace("\t", " ").replace("\n", " "))
rng = random.Random(20261110)
sample = rng.sample(sorted(by_image), 300)
with open(os.path.join(out, "phrases_sample.tsv"), "w", encoding="utf-8") as f:
    for img in sample:
        f.write(f"{img}\t{rng.choice(by_image[img])}\n")
print(f"{len(queries)} queries ({len(top_pairs)} pairs), 300 sampled captions -> {out}")
print("pairs:", ", ".join(f"{a}+{b}({pairs[(a, b)]})" for a, b in top_pairs))
