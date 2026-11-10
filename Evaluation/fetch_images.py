#!/usr/bin/env python3
"""从 Wikimedia Commons 下载评测图片，并记录每张图的作者和许可证。

用法：python3 fetch_images.py <图片目录>
- 每个类别先在 Commons 的「Quality images」里找，不够再在全部文件里找。
- 图片保存为 <类别>_<序号>.jpg（宽 1024 像素的缩略图）；作者和许可证写到本脚本旁边的 image_credits.tsv。
- 只用公开、自由许可的图片，不含任何私人照片。
"""
import html
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

UA = "TuSouEvaluation/1.0 (offline photo search research script)"

# (类别, Commons 搜索词, 张数)
CATEGORIES = [
    ("cat", "domestic cat", 6),
    ("dog", "dog portrait", 6),
    ("beachsunset", "sunset beach sea", 6),
    ("cake", "birthday cake candles", 5),
    ("snowmountain", "snow mountain peak", 6),
    ("redcar", "red car", 6),
    ("bluecar", "blue car", 3),
    ("citynight", "city skyline night", 6),
    ("bicycle", "cyclist riding bicycle", 6),
    ("rain", "rain street umbrella", 6),
    ("noodles", "ramen noodle bowl", 6),
    ("flowers", "flower garden", 6),
    ("menu", "restaurant menu board", 5),
    ("waterfall", "waterfall", 6),
    ("balloon", "hot air balloon", 6),
    ("children", "children playing", 6),
    ("basketball", "basketball game", 5),
    ("bridge", "bridge river", 5),
    ("dogbeach", "dog on beach", 5),
    ("interior", "building interior hall", 4),
    ("forest", "forest path", 4),
]

EXCLUDE = re.compile(r"map|diagram|logo|drawing|painting|illustration|poster|stamp|scan|icon|chart|svg|collage", re.I)


def api(params):
    url = "https://commons.wikimedia.org/w/api.php?" + urllib.parse.urlencode(params)
    for attempt in range(6):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except urllib.error.HTTPError as e:
            if e.code != 429:
                raise
            wait = 20 * (attempt + 1)
            print(f"  API 限流，等待 {wait} 秒", flush=True)
            time.sleep(wait)
    raise SystemExit("API 一直限流，稍后再试")


def search(terms, quality):
    query = f"{terms} filetype:bitmap" + (" incategory:Quality_images" if quality else "")
    data = api({
        "action": "query", "format": "json", "generator": "search", "gsrsearch": query,
        "gsrnamespace": 6, "gsrlimit": 30, "prop": "imageinfo",
        "iiprop": "url|mime|size|extmetadata", "iiurlwidth": 1024,
        "iiextmetadatafilter": "LicenseShortName|Artist",
    })
    pages = sorted(data.get("query", {}).get("pages", {}).values(), key=lambda p: p.get("index", 0))
    out = []
    for p in pages:
        info = (p.get("imageinfo") or [{}])[0]
        w, h = info.get("width", 0), info.get("height", 0)
        if info.get("mime") != "image/jpeg" or w < 1000 or h < 600 or not (0.5 <= w / max(h, 1) <= 2.2):
            continue
        if EXCLUDE.search(p["title"]):
            continue
        meta = info.get("extmetadata", {})
        license_name = meta.get("LicenseShortName", {}).get("value", "")
        if not license_name:
            continue
        artist = re.sub(r"<[^>]+>", "", html.unescape(meta.get("Artist", {}).get("value", ""))).strip()
        out.append({"title": p["title"], "thumb": info.get("thumburl") or info["url"],
                    "page": info.get("descriptionurl", ""), "license": license_name, "artist": artist})
    return out


def download(url, dest):
    for attempt in range(5):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": UA})
            with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as f:
                f.write(r.read())
            return True
        except urllib.error.HTTPError as e:
            if e.code != 429:
                print(f"  下载失败 {e.code}: {url}")
                return False
            time.sleep(15 * (attempt + 1))
    return False


def main():
    outdir = sys.argv[1]
    os.makedirs(outdir, exist_ok=True)
    credits = []
    seen = set()
    for name, terms, count in CATEGORIES:
        picked = []
        for quality in (True, False):
            for item in search(terms, quality):
                if len(picked) == count:
                    break
                if item["title"] not in seen:
                    seen.add(item["title"])
                    picked.append(item)
            time.sleep(1)
            if len(picked) == count:
                break
        for i, item in enumerate(picked, 1):
            file_name = f"{name}_{i}.jpg"
            if download(item["thumb"], os.path.join(outdir, file_name)):
                credits.append((file_name, item["title"], item["artist"], item["license"], item["page"]))
            time.sleep(0.5)
        print(f"{name}: {len(picked)} 张", flush=True)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "image_credits.tsv")
    with open(path, "w", encoding="utf-8") as f:
        f.write("file\tcommons_title\tartist\tlicense\tsource\n")
        for row in credits:
            f.write("\t".join(c.replace("\t", " ").replace("\n", " ") for c in row) + "\n")
    print(f"共 {len(credits)} 张，来源与许可证见 {path}")


if __name__ == "__main__":
    main()
