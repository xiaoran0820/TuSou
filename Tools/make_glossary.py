#!/usr/bin/env python3
"""由 CC-CEDICT 生成 App 用的中英对照表 ImageSearch/Resources/cedict-glossary.tsv。

用法：python3 make_glossary.py <cedict_ts.u8> <输出 tsv>
- CC-CEDICT 由 MDBG 发布，许可证 CC BY-SA 4.0；生成的对照表沿用同一许可证（见 ThirdPartyNotices.md）。
- 每个简体词（两个字以上）只留一个适合描述图片的英文释义，交给 MobileCLIP 用：
  普通词优先于专有名词（「汉堡」取 hamburger，不取德国城市 Hamburg）；
  跳过「见某词」「异体字」「量词」等释义，跳过人名（姓氏）条目和「两头」「三个」这类数量短语；
  动词为主的词只取 -ing 形式（滑雪 → skiing），没有就不翻；
  去掉拼音、汉字、开头的括号注释（如 (loanword)），在第一个逗号、分号或括号处截断，去掉变音符号（Kyōto → Kyoto）。
"""
import re
import sys
import unicodedata

SKIP = re.compile(
    r"^(see also |see |variant of |old variant of |archaic variant of |also written |also pr\. |surname |CL:|"
    r"abbr\. |abbr for |abbreviation for |used in |Taiwan pr\. |pr\. |lit\. |fig\. |classifier for |"
    r"Japanese variant of |erhua variant of |informal name of |formal name of |short name for |short for )",
    re.I,
)
MAX_WORDS = 6


def clean(gloss):
    g = re.sub(r"\[[^\]]*\]", "", gloss)                      # 拼音
    g = re.sub(r"[㐀-鿿豈-﫿|]+", " ", g)     # 汉字和交叉引用里的 |
    while True:                                               # 开头的括号注释：(loanword) (coll.) …
        m = re.match(r"^\s*\([^)]*\)\s*", g)
        if not m:
            break
        g = g[m.end():]
    g = re.split(r"\s*[(;,]", g)[0]
    g = unicodedata.normalize("NFKD", g).encode("ascii", "ignore").decode()
    g = re.sub(r"\s+", " ", g).strip(" .'\"")
    return g


PERSON = re.compile(r"surname|given name|personal name", re.I)
COUNTING = re.compile(r"^[一二两三四五六七八九十几半多][只头匹个辆条张位对棵朵片块本支根把件双名座间台架艘颗粒杯碗盘份层]$")


def usable(g):
    if len(g.split()) > MAX_WORDS and " in " in g:   # 「… pavilion in northwest Kyoto」去掉地点短语
        g = g.split(" in ")[0]
    return g if 1 <= len(g.split()) <= MAX_WORDS and re.search(r"[A-Za-z]", g) else None


def pick(entries):
    """entries：同一个简体词的全部条目 [(拼音, [释义…])]，按词典顺序。
    普通词优先于专有名词；跳过人名（姓氏）条目；第一个释义就是「to …」的条目是动词为主的词，
    只取 skiing、surfing 这类 -ing 形式，没有就不翻（「开放」的 unrestrained by convention、「停车」的 pull up 都不合适）。"""
    common = [e for e in entries if e[0][:1].islower()]
    for _, glosses in (common or entries):
        raws = [r.strip() for r in glosses if r.strip() and not SKIP.match(r.strip())]
        if not raws or any(PERSON.search(r) for r in raws):
            continue
        cleaned = [clean(r) for r in raws]
        if cleaned[0].lower().startswith("to "):
            for g in cleaned[1:]:
                if not g.lower().startswith("to ") and g.split() and g.split()[0].lower().endswith("ing"):
                    if (u := usable(g)) and len(u.split()) <= 3:
                        return u
            continue
        for g in cleaned:
            if not g.lower().startswith("to ") and (u := usable(g)):
                return u
    return None


def main():
    src, dst = sys.argv[1], sys.argv[2]
    entries, version = {}, ""
    with open(src, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#"):
                m = re.match(r"#! date=(\S+)", line)
                if m:
                    version = m.group(1)
                continue
            m = re.match(r"(\S+) (\S+) \[([^\]]*)\] /(.*)/\s*$", line)
            if m and len(m.group(2)) >= 2:
                entries.setdefault(m.group(2), []).append((m.group(3), m.group(4).split("/")))
    rows = sorted((w, g) for w, e in entries.items() if not COUNTING.match(w) and (g := pick(e)))
    with open(dst, "w", encoding="utf-8") as f:
        f.write("# Chinese-English glossary for TuSou, derived from CC-CEDICT"
                f"{' (release ' + version + ')' if version else ''}, published by MDBG: https://www.mdbg.net/chinese/dictionary?page=cc-cedict\n")
        f.write("# License: Creative Commons Attribution-ShareAlike 4.0 International, https://creativecommons.org/licenses/by-sa/4.0/\n")
        f.write("# Changes: simplified headwords of two or more characters, one cleaned English gloss each (Tools/make_glossary.py).\n")
        for w, g in rows:
            f.write(f"{w}\t{g}\n")
    print(f"{len(rows)} entries (of {len(entries)} headwords) -> {dst}")


if __name__ == "__main__":
    main()
