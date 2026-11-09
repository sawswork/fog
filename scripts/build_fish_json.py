#!/usr/bin/env python3
"""集めた素材から fish.json を組み立てる（F-60）。

入力（作業フォルダ、既定は scratchpad/fish）
- japan_checklist.json   FishBase の日本の魚種一覧（学名・目・科・英名・和名ローマ字・在来/移入/固有）
- wd_by_fishbase.json    Wikidata（FishBase ID → QID・和名・日本語版の記事名・Commons の画像名）
- fishbase_data.json     FishBase の種の要約（最大全長・水深・水温・環境・分布 …）
- wikitext.json          Wikipedia 日本語版の記事（記事名 → wikitext、ダンプから）
- image_credits.json     取り込めた画像のクレジット
- scripts/fish_species_list.json  手で付けた釣りの分類タグ・別名（和名か学名で対応づける）

使い方: python3 scripts/build_fish_json.py --work <folder> --out Packages/Core/Sources/Core/Data/fish.json --images App/Resources/Fish
"""
import argparse, json, os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fetch_fish_db as F
from romaji_kana import romaji_to_katakana

ap = argparse.ArgumentParser()
ap.add_argument("--work", required=True); ap.add_argument("--out", required=True); ap.add_argument("--images", required=True)
a = ap.parse_args()
W = a.work
def load(name, default):
    p = os.path.join(W, name)
    return json.load(open(p, encoding="utf-8")) if os.path.exists(p) else default
checklist = load("japan_checklist.json", [])
wd = load("wd_by_fishbase.json", {})
fb = load("fishbase_data.json", {})
wikitext = load("wikitext.json", {})
credits = load("image_credits.json", {})
curated = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fish_species_list.json"), encoding="utf-8"))
cur_by_name = {}
cur_by_sci = {}
for c in curated:
    for k in [c["name"], c.get("wikipedia")] + c.get("aliases", []):
        if k: cur_by_name.setdefault(k, c)
    # 学名は Wikipedia の分類表から（手の一覧には書いていない）
    sci = c.get("scientificName") or F.taxobox_sciname(wikitext.get(c.get("wikipedia") or c["name"], ""))
    if sci: c["_sci"] = sci; cur_by_sci.setdefault(sci, c)

def wiki_fields(title):
    wt = wikitext.get(title)
    if not wt: return {}
    text = F.wikitext_to_plain(wt)
    sec = F.sections(text)
    out = {
        "summary": F.clean(sec.get("lead", ""), 600),
        "morphology": F.clean(F.find_section(sec, ["形態", "特徴"]), 700),
        "ecology": F.clean(F.find_section(sec, ["生態", "習性"]), 800),
        "distributionJa": F.clean(F.find_section(sec, ["分布", "生息"]), 400),
        "usage": F.clean(F.find_section(sec, ["人間との関わり", "利用", "釣り", "食材", "漁業"]), 600),
    }
    out["spawning"] = F.spawning_from(sec); out["spawningMonths"] = F.months_from(out["spawning"])
    out["seasonNote"] = F.season_from(sec); out["seasonMonths"] = F.months_from(out["seasonNote"])
    fam = F.taxobox_family(wt)
    if fam: out["family"] = fam
    return {k: v for k, v in out.items() if v}

entries = []; seen_cur = set()
for o in checklist:
    code = str(o["specCode"]); w = wd.get(code, {})
    ja = w.get("ja") or w.get("jawiki")
    # 「○○ (魚)」のような記事名は括弧を外す
    if ja: ja = re.sub(r"\s*[（(][^）)]*[）)]\s*$", "", ja)
    cur = cur_by_name.get(ja) or cur_by_name.get(w.get("jawiki") or "") or cur_by_sci.get(o["scientificName"])
    if cur and cur["id"] in seen_cur: cur = None   # 同じ手選びの種を 2 回使わない（亜種など）
    estimated = romaji_to_katakana(o["jaRomaji"]) if o.get("jaRomaji") else None
    if not cur and estimated:
        # Wikidata に和名が無くても、FishBase のローマ字をカタカナにしたものが手選びの名前と同じなら同じ種
        cand = cur_by_name.get(estimated)
        if cand and cand["id"] not in seen_cur: cur = cand
    if ja or cur: estimated_used = False
    name = (cur["name"] if cur else None) or ja or estimated or o["scientificName"]
    e = {"id": (cur["id"] if cur else f"fb{code}"), "name": name, "aliases": list(cur.get("aliases", [])) if cur else [], "groups": list(cur.get("groups", [])) if cur else [],
         "scientificName": o["scientificName"], "englishName": o.get("englishName") or None, "nameRomaji": o.get("jaRomaji") or None,
         "nameEstimated": True if (estimated and name == estimated and not ja and not cur) else None,
         "familySci": o.get("family"), "order": o.get("order"), "status": o.get("status"), "sources": []}
    if ja and cur and ja != cur["name"] and ja not in e["aliases"]: e["aliases"].append(ja)
    if w.get("qid"): e["wikidata"] = w["qid"]
    if cur: seen_cur.add(cur["id"])
    title = w.get("jawiki") or (cur and (cur.get("wikipedia") or cur["name"]) if cur and (cur.get("wikipedia") or cur["name"]) in wikitext else None)
    if title:
        e.update(wiki_fields(title))
        e["sources"].append({"name": f"Wikipedia 日本語版「{title}」(CC BY-SA 4.0)", "url": "https://ja.wikipedia.org/wiki/" + title.replace(" ", "_")})
    d = fb.get(code, {})
    if "maxLengthCm" in d:
        for k in ("maxLengthCm", "lengthType", "commonLengthCm", "maxWeightKg", "maturityLengthCm", "environment", "waters", "habitatType", "migration", "depthMinM", "depthMaxM", "climate", "tempMinC", "tempMaxC", "distribution", "description", "biology", "reproduction"):
            if k in d: e[k] = d[k]
        e["sources"].append({"name": "FishBase (Froese & Pauly, CC BY-NC 3.0)", "url": f"https://www.fishbase.se/summary/{code}"})
    cr = credits.get(e["id"]) or credits.get(f"fb{code}")
    img_file = None
    for cand in (e["id"] + ".jpg", f"fb{code}.jpg"):
        if os.path.exists(os.path.join(a.images, cand)): img_file = cand; break
    if img_file and cr and "file" in cr:
        e["image"] = img_file; e["imageCredit"] = cr
        e["sources"].append({"name": "Wikimedia Commons（画像）", "url": cr.get("url")})
    e = {k: v for k, v in e.items() if v not in (None, "", [], {})}
    entries.append(e)

# 一覧に無い手選びの種（イカ・タコ・エビなど FishBase 外）：Wikipedia の記事があれば入れる
for c in curated:
    if c["id"] in seen_cur: continue
    title = c.get("wikipedia") or c["name"]
    e = {"id": c["id"], "name": c["name"], "aliases": c.get("aliases", []), "groups": c.get("groups", []), "sources": []}
    if title in wikitext:
        e.update(wiki_fields(title))
        e["sources"].append({"name": f"Wikipedia 日本語版「{title}」(CC BY-SA 4.0)", "url": "https://ja.wikipedia.org/wiki/" + title.replace(" ", "_")})
    else:
        e["missing"] = True
    cr = credits.get(c["id"])
    if cr and "file" in cr and os.path.exists(os.path.join(a.images, c["id"] + ".jpg")):
        e["image"] = c["id"] + ".jpg"; e["imageCredit"] = cr; e["sources"].append({"name": "Wikimedia Commons（画像）", "url": cr.get("url")})
    entries.append({k: v for k, v in e.items() if v not in (None, "", [], {})})

# 並び：釣りの分類がある種（五十音）→ 和名のある種（五十音）→ 推定和名 → 学名だけ
def rank(e):
    if e.get("groups"): return 0
    if e.get("name") != e.get("scientificName") and not e.get("nameEstimated"): return 1
    if e.get("nameEstimated"): return 2
    return 3
entries.sort(key=lambda e: (rank(e), e.get("name")))
json.dump({"generatedAt": time.strftime("%Y-%m-%d"), "entries": entries}, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, separators=(",", ":"))
named = sum(1 for e in entries if e.get("name") != e.get("scientificName") and not e.get("nameEstimated")); est = sum(1 for e in entries if e.get("nameEstimated")); imgs = sum(1 for e in entries if e.get("image")); fbn = sum(1 for e in entries if e.get("maxLengthCm")); wk = sum(1 for e in entries if e.get("summary"))
print(f"fish.json: {len(entries)} 種、和名 {named}（推定 {est}）、FishBase {fbn}、Wikipedia {wk}、画像 {imgs}、{os.path.getsize(a.out)//1024} KB")
