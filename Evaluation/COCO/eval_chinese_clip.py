#!/usr/bin/env python3
"""在 Mac 上评估 Chinese-CLIP（OFA-Sys/chinese-clip-vit-base-patch16，MIT 许可）能不能替代「中文翻译 + MobileCLIP」。

用法：python eval_chinese_clip.py <模型目录> <val2017 图片目录> <queries_zh.json> <phrases_zh.tsv> <instances_val2017.json> <结果 JSON>
需要 torch、transformers、pillow、numpy。和 main.swift 的方案 E 用同样的口径：只按相似度给 5,000 张图排序，
中文物体查询看 P@10 和 AP（相关 = 该类物体占画面 ≥ 1%，更小的不计入），中文短语看对应的那张图排第几。
"""
import json
import os
import sys
import time

import numpy as np
import torch
from PIL import Image
from transformers import ChineseCLIPModel, ChineseCLIPProcessor

model_dir, img_dir, queries_path, phrases_path, inst_path, out_path = sys.argv[1:7]
device = "mps" if torch.backends.mps.is_available() else "cpu"
model = ChineseCLIPModel.from_pretrained(model_dir).to(device).eval()
proc = ChineseCLIPProcessor.from_pretrained(model_dir)

def features(out):
    """transformers 4 直接返回投影后的向量；5 起返回结果对象，向量在 pooler_output 里"""
    return out if torch.is_tensor(out) else out.pooler_output


files = sorted(f for f in os.listdir(img_dir) if f.endswith(".jpg"))
ids = [str(int(f[:-4])) for f in files]
index = {k: i for i, k in enumerate(ids)}
cache = os.path.join(os.path.dirname(os.path.abspath(out_path)), "cnclip_image_embeddings.npy")
t0 = time.time()
if os.path.exists(cache):
    img = np.load(cache)
else:
    parts = []
    for s in range(0, len(files), 64):
        batch = [Image.open(os.path.join(img_dir, f)).convert("RGB") for f in files[s:s + 64]]
        with torch.no_grad():
            x = proc(images=batch, return_tensors="pt")["pixel_values"].to(device)
            parts.append(torch.nn.functional.normalize(features(model.get_image_features(pixel_values=x)), dim=-1).cpu().numpy())
    img = np.concatenate(parts)
    np.save(cache, img)
print(f"图片 {len(ids)} 张，编码用时 {time.time() - t0:.0f} 秒", flush=True)


def encode(texts):
    parts = []
    for s in range(0, len(texts), 128):
        with torch.no_grad():
            t = proc(text=texts[s:s + 128], padding=True, truncation=True, max_length=52, return_tensors="pt").to(device)
            parts.append(torch.nn.functional.normalize(features(model.get_text_features(**t)), dim=-1).cpu().numpy())
    return np.concatenate(parts)


# 相关性（和 main.swift 一样）
inst = json.load(open(inst_path))
cat_name = {c["id"]: c["name"] for c in inst["categories"]}
area = {im["id"]: im["width"] * im["height"] for im in inst["images"]}
largest = {}
for a in inst["annotations"]:
    d = largest.setdefault(cat_name[a["category_id"]], {})
    k = str(a["image_id"])
    d[k] = max(d.get(k, 0), a["area"] / area[a["image_id"]])


def judge(cats):
    rel = present = None
    for c in cats:
        m = largest.get(c, {})
        r = {k for k, v in m.items() if v >= 0.01}
        rel = r if rel is None else rel & r
        present = set(m) if present is None else present & set(m)
    return rel or set(), (present or set()) - (rel or set())


queries = json.load(open(queries_path, encoding="utf-8"))
phrases = [l.rstrip("\n").split("\t") for l in open(phrases_path, encoding="utf-8") if not l.startswith("#")]
result = {"model": os.path.basename(model_dir.rstrip("/")), "images": len(ids)}
for name, template in (("原文", "{}"), ("模板「一张…的照片」", "一张{}的照片。")):
    qs = [q for q in queries if len(judge(q["categories"])[0]) >= 5]
    qe = encode([template.format(q["query"]) for q in qs])
    p10s, aps = [], []
    for q, v in zip(qs, qe):
        rel, ignore = judge(q["categories"])
        order = [ids[i] for i in np.argsort(-(img @ v)) if ids[i] not in ignore]
        top = order[:10]
        p10s.append(sum(k in rel for k in top) / len(top))
        hits = s = 0
        for i, k in enumerate(order):
            if k in rel:
                hits += 1
                s += hits / (i + 1)
        aps.append(s / len(rel))
    pe = encode([template.format(p[2]) for p in phrases])
    ranks = []
    for p, v in zip(phrases, pe):
        sims = img @ v
        ranks.append(int((sims > sims[index[p[0]]]).sum()) + 1)
    r = lambda k: sum(x <= k for x in ranks) / len(ranks)
    result[name] = {"object_queries": len(qs), "P@10": float(np.mean(p10s)), "AP": float(np.mean(aps)),
                    "phrases": len(ranks), "R@1": r(1), "R@5": r(5), "R@10": r(10), "R@50": r(50)}
    print(f"{name:<14} 物体查询 {len(qs)} 个：P@10 {np.mean(p10s):.3f}  AP {np.mean(aps):.3f} | "
          f"中文短语 {len(ranks)} 条：R@1 {r(1):.1%}  R@5 {r(5):.1%}  R@10 {r(10):.1%}  R@50 {r(50):.1%}", flush=True)
json.dump(result, open(out_path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
