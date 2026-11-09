#!/usr/bin/env python3
"""全国の釣り魚データベース（図鑑 F-60）を信頼できる出典から集める。

出典
- Wikidata: 学名・分類・FishBase ID・Commons の画像名（CC0）
- Wikimedia Commons: 画像本体とライセンス・作者（CC BY / CC BY-SA / CC0 / パブリックドメインのものだけ使う）
- Wikipedia 日本語版: 解説（形態・生態・分布・利用）。CC BY-SA 4.0、出典として記事名を記録
- FishBase (fishbase.se): 最大全長・一般的な全長・生息環境・水深・水温・分布。CC BY-NC 3.0、出典として記録

使い方: python3 scripts/fetch_fish_db.py --out Packages/Core/Sources/Core/Resources/Data/fish.json --images App/Resources/Fish [--only アイナメ,クロソイ] [--limit N]
依存: requests, Pillow
"""
import argparse, json, os, re, sys, time, io, html
import requests
from PIL import Image

UA = "FogFishGuide/1.0 (personal fishing app, https://github.com/sawswork/fog)"
S = requests.Session(); S.headers["User-Agent"] = UA
HERE = os.path.dirname(os.path.abspath(__file__))
OK_LICENSES = ("CC BY-SA", "CC BY ", "CC BY-", "CC0", "Public domain", "CC-BY", "cc-by", "pd", "PD", "Attribution")

def wd_search(name):
    r = S.get("https://www.wikidata.org/w/api.php", params={"action": "wbsearchentities", "search": name, "language": "ja", "format": "json", "limit": 8, "type": "item"}, timeout=30)
    r.raise_for_status()
    return r.json().get("search", [])

def wd_entities(ids):
    r = S.get("https://www.wikidata.org/w/api.php", params={"action": "wbgetentities", "ids": "|".join(ids), "props": "claims|sitelinks|labels|aliases", "languages": "ja|en", "format": "json"}, timeout=30)
    r.raise_for_status()
    return r.json().get("entities", {})

def claim(e, p):
    try: return e["claims"][p][0]["mainsnak"]["datavalue"]["value"]
    except Exception: return None

def claims_all(e, p):
    out = []
    for c in e.get("claims", {}).get(p, []):
        try: out.append(c["mainsnak"]["datavalue"]["value"])
        except Exception: pass
    return out

def pick_taxon(name, aliases):
    """検索結果から「種」の分類群を選ぶ（学名があり、日本語版の記事があるもの）"""
    cands = wd_search(name)
    if not cands: return None
    ents = wd_entities([c["id"] for c in cands])
    best = None
    for c in cands:
        e = ents.get(c["id"])
        if not e or not claim(e, "P225"): continue
        rank = claim(e, "P105")
        rank_id = rank.get("id") if isinstance(rank, dict) else None
        label = e.get("labels", {}).get("ja", {}).get("value", "")
        score = 0
        if rank_id == "Q7432": score += 3          # 種
        elif rank_id in ("Q68947", "Q767728"): score += 1   # 亜種・変種
        if "jawiki" in e.get("sitelinks", {}): score += 2
        if label == name: score += 2
        if claim(e, "P18"): score += 1
        if claim(e, "P938"): score += 1
        if best is None or score > best[0]: best = (score, e)
    return best[1] if best and best[0] >= 3 else None

def commons_image(filename):
    r = S.get("https://commons.wikimedia.org/w/api.php", params={"action": "query", "titles": "File:" + filename, "prop": "imageinfo", "iiprop": "url|extmetadata|size|mime", "iiurlwidth": 1000, "format": "json"}, timeout=30)
    r.raise_for_status()
    pages = r.json().get("query", {}).get("pages", {})
    for p in pages.values():
        ii = (p.get("imageinfo") or [{}])[0]
        m = ii.get("extmetadata", {})
        g = lambda k: html.unescape(re.sub(r"<[^>]+>", "", m.get(k, {}).get("value", ""))).strip()
        lic = g("LicenseShortName") or g("License")
        return {"url": ii.get("thumburl") or ii.get("url"), "license": lic, "licenseURL": g("LicenseUrl"), "artist": g("Artist")[:120], "credit": g("Credit")[:120],
                "descURL": ii.get("descriptionurl"), "mime": ii.get("mime")}
    return None

def license_ok(lic):
    l = (lic or "").lower()
    if not l: return False
    if "nc" in l or "nd" in l: return False
    return any(k in l for k in ("cc by", "cc-by", "cc0", "public domain", "pd", "attribution", "gfdl", "free art"))

def wiki_extract(title):
    r = S.get("https://ja.wikipedia.org/w/api.php", params={"action": "query", "prop": "extracts|info", "explaintext": 1, "titles": title, "format": "json", "inprop": "url", "redirects": 1}, timeout=30)
    r.raise_for_status()
    for p in r.json().get("query", {}).get("pages", {}).values():
        return p.get("extract", ""), p.get("fullurl", "")
    return "", ""

def sections(text):
    """== 見出し == で分ける。先頭は lead"""
    out = {"lead": ""}; cur = "lead"
    for line in text.split("\n"):
        m = re.match(r"^=+\s*(.+?)\s*=+$", line)
        if m: cur = m.group(1); out.setdefault(cur, ""); continue
        out[cur] = out.get(cur, "") + line + "\n"
    return {k: v.strip() for k, v in out.items()}

def find_section(sec, keys):
    for k, v in sec.items():
        if any(x in k for x in keys) and v: return v
    return ""

def clean(t, limit):
    t = re.sub(r"\n{2,}", "\n", t or "").strip()
    t = re.sub(r"（[^）]*学名[^）]*）", "", t)
    return t[:limit].rstrip()

def fishbase(sci, spec_code=None):
    url = f"https://www.fishbase.se/summary/{sci.replace(' ', '-')}.html" if not spec_code else f"https://www.fishbase.se/summary/{spec_code}"
    try:
        r = S.get(url, timeout=40)
        if r.status_code != 200 or "Max length" not in r.text:
            if spec_code and sci:
                r = S.get(f"https://www.fishbase.se/summary/{sci.replace(' ', '-')}.html", timeout=40)
        t = html.unescape(re.sub(r"<[^>]+>", " ", r.text)); t = re.sub(r"\s+", " ", t)
    except Exception as ex:
        return {"error": str(ex)[:80]}
    out = {"url": url}
    m = re.search(r"Max length\s*:\s*([\d.]+)\s*cm\s*(TL|SL|FL|ML|WD|NG|OT)?", t)
    if m: out["maxLengthCm"] = float(m.group(1)); out["lengthType"] = m.group(2) or "TL"
    m = re.search(r"common length\s*:\s*([\d.]+)\s*cm", t)
    if m: out["commonLengthCm"] = float(m.group(1))
    m = re.search(r"max\.? published weight\s*:\s*([\d.,]+)\s*(kg|g)", t)
    if m:
        w = float(m.group(1).replace(",", "")); out["maxWeightKg"] = w if m.group(2) == "kg" else w / 1000
    m = re.search(r"Environment:[^A-Za-z]*(?:milieu / climate zone / depth range / distribution range)?\s*(Marine|Freshwater|Brackish)[^.]*?\.", t)
    env_line = re.search(r"(Marine|Freshwater|Brackish)[;,][^.]{0,120}?(demersal|pelagic|benthopelagic|reef-associated|bathydemersal|bathypelagic|pelagic-neritic|pelagic-oceanic)[^.]*", t)
    if env_line:
        s = env_line.group(0)
        out["environment"] = s[:160]
        out["waters"] = [w for w in ("Marine", "Freshwater", "Brackish") if w.lower() in s.lower()]
        out["habitatType"] = env_line.group(2)
        d = re.search(r"depth range\s*(\d+)\s*-\s*(\d+)\s*m", s)
        if d: out["depthMinM"] = int(d.group(1)); out["depthMaxM"] = int(d.group(2))
        else:
            d = re.search(r"depth range\s*\?\s*-\s*(\d+)\s*m", s)
            if d: out["depthMaxM"] = int(d.group(1))
    m = re.search(r"(Tropical|Subtropical|Temperate|Boreal|Polar|Deep-water)\s*;?\s*(?:([\d.]+)°C\s*-\s*([\d.]+)°C)?", t)
    if m:
        out["climate"] = m.group(1)
        if m.group(2): out["tempMinC"] = float(m.group(2)); out["tempMaxC"] = float(m.group(3))
    m = re.search(r"Distribution\s+Countries\s*\|\s*FAO areas\s*\|\s*Ecosystems\s*\|\s*Occurrences\s*\|\s*Point map\s*\|\s*Introductions\s*\|\s*Faunafri\s*(.*?)(?:Length at first maturity|Size / Weight / Age)", t)
    if m: out["distribution"] = m.group(1).strip()[:400]
    m = re.search(r"Short description.*?(?:Morphology \| Morphometrics)\s*(.*?)(?:Biology|Life cycle)", t)
    if m: out["description"] = m.group(1).strip()[:500]
    m = re.search(r"Biology\s+Glossary\s*\(e\.g\. epibenthic\)\s*(.*?)(?:Life cycle and mating behavior|IUCN Red List Status)", t)
    if m: out["biology"] = m.group(1).strip()[:700]
    m = re.search(r"Life cycle and mating behavior\s+Maturity \| Reproduction \| Spawning \| Eggs \| Fecundity \| Larvae\s*(.*?)(?:Main reference|IUCN)", t)
    if m and len(m.group(1).strip()) > 10: out["reproduction"] = m.group(1).strip()[:400]
    return out

MONTHS = {"1": 1, "一": 1, "2": 2, "二": 2, "3": 3, "三": 3, "4": 4, "四": 4, "5": 5, "五": 5, "6": 6, "六": 6, "7": 7, "七": 7, "8": 8, "八": 8, "9": 9, "九": 9, "10": 10, "十": 10, "11": 11, "十一": 11, "12": 12, "十二": 12}
SEASON_MONTHS = {"春": [3, 4, 5], "夏": [6, 7, 8], "秋": [9, 10, 11], "冬": [12, 1, 2], "初夏": [5, 6], "晩秋": [10, 11], "初春": [2, 3], "晩夏": [8, 9], "初冬": [11, 12], "真冬": [1, 2], "早春": [2, 3], "梅雨": [6]}

def months_from(text):
    """「産卵期は4-6月」「春から初夏」などから月の集合を取る"""
    if not text: return []
    out = set()
    for m in re.finditer(r"(\d{1,2})\s*[-〜～–-]\s*(\d{1,2})\s*月", text):
        a, b = int(m.group(1)), int(m.group(2))
        if 1 <= a <= 12 and 1 <= b <= 12:
            i = a
            while True:
                out.add(i)
                if i == b: break
                i = i % 12 + 1
    for m in re.finditer(r"(\d{1,2})\s*月", text):
        v = int(m.group(1))
        if 1 <= v <= 12: out.add(v)
    if not out:
        m = re.search(r"(初春|早春|晩春|春|初夏|梅雨|晩夏|夏|晩秋|秋|初冬|真冬|冬)(?:から|〜|～|-|–)(初春|早春|晩春|春|初夏|晩夏|夏|晩秋|秋|初冬|真冬|冬)", text)
        if m:
            a = SEASON_MONTHS.get(m.group(1), []); b = SEASON_MONTHS.get(m.group(2), [])
            if a and b:
                i = a[0]
                while True:
                    out.add(i)
                    if i == b[-1]: break
                    i = i % 12 + 1
        else:
            for k, v in SEASON_MONTHS.items():
                if k in text: out.update(v); break
    return sorted(out)

def spawning_from(sec):
    for k in ("生態", "繁殖", "産卵", "生活史"):
        t = find_section(sec, [k])
        m = re.search(r"産卵[期時][^。]{0,60}", t or "")
        if m: return m.group(0)
    t = sec.get("lead", "")
    m = re.search(r"産卵[期時][^。]{0,60}", t)
    return m.group(0) if m else ""

def season_from(sec):
    for k in ("人間", "利用", "釣り", "漁業", "食"):
        t = find_section(sec, [k])
        m = re.search(r"旬[^。]{0,40}", t or "")
        if m: return m.group(0)
    return ""

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True); ap.add_argument("--images", required=True)
    ap.add_argument("--only", default=""); ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--list", default=os.path.join(HERE, "fish_species_list.json"))
    ap.add_argument("--resume", action="store_true", help="既存の out を読み、済んだ魚は飛ばす")
    a = ap.parse_args()
    species = json.load(open(a.list, encoding="utf-8"))
    only = set(x for x in a.only.split(",") if x)
    os.makedirs(a.images, exist_ok=True)
    done = {}
    if a.resume and os.path.exists(a.out):
        for e in json.load(open(a.out, encoding="utf-8"))["entries"]: done[e["name"]] = e
    entries = []; n = 0
    for sp in species:
        name = sp["name"]
        if only and name not in only: continue
        if name in done: entries.append(done[name]); continue
        if a.limit and n >= a.limit: break
        n += 1
        print(f"[{n}] {name}", flush=True)
        entry = {"id": sp["id"], "name": name, "aliases": sp.get("aliases", []), "groups": sp.get("groups", []), "sources": []}
        try:
            e = pick_taxon(sp.get("wikidata") or name, sp.get("aliases", []))
            if e is None:
                print("   ! Wikidata で見つからず"); entry["missing"] = True; entries.append(entry); continue
            entry["wikidata"] = e["id"]
            entry["scientificName"] = claim(e, "P225")
            en = e.get("labels", {}).get("en", {}).get("value")
            if en and en != entry["scientificName"]: entry["englishName"] = en
            fb_id = claim(e, "P938")
            ja_title = e.get("sitelinks", {}).get("jawiki", {}).get("title")
            # 分類（科）：親をたどる（最大 4 段）
            parent = claim(e, "P171"); fam = None
            for _ in range(5):
                if not isinstance(parent, dict): break
                pe = wd_entities([parent["id"]]).get(parent["id"], {})
                rank = claim(pe, "P105")
                if isinstance(rank, dict) and rank.get("id") == "Q35409":   # 科
                    fam = pe.get("labels", {}).get("ja", {}).get("value") or claim(pe, "P225"); break
                parent = claim(pe, "P171")
            if fam: entry["family"] = fam
            # 画像
            img = claim(e, "P18")
            if img:
                info = commons_image(img)
                if info and license_ok(info.get("license")) and info.get("url"):
                    try:
                        r = S.get(info["url"], timeout=60); r.raise_for_status()
                        im = Image.open(io.BytesIO(r.content)).convert("RGB")
                        im.thumbnail((900, 900))
                        path = os.path.join(a.images, f"{sp['id']}.jpg"); im.save(path, "JPEG", quality=82, optimize=True)
                        entry["image"] = f"{sp['id']}.jpg"
                        entry["imageCredit"] = {"file": img, "license": info["license"], "artist": info["artist"], "url": info["descURL"], "licenseURL": info.get("licenseURL", "")}
                        entry["sources"].append({"name": "Wikimedia Commons", "url": info["descURL"]})
                    except Exception as ex:
                        print("   ! 画像の取得に失敗", str(ex)[:80])
                else:
                    print("   ! 画像のライセンスが条件外:", info and info.get("license"))
            # Wikipedia 日本語
            if ja_title:
                text, url = wiki_extract(ja_title)
                sec = sections(text)
                entry["summary"] = clean(sec.get("lead", ""), 600)
                entry["morphology"] = clean(find_section(sec, ["形態", "特徴"]), 700)
                entry["ecology"] = clean(find_section(sec, ["生態", "習性"]), 800)
                entry["distributionJa"] = clean(find_section(sec, ["分布", "生息"]), 400)
                entry["usage"] = clean(find_section(sec, ["人間との関わり", "利用", "釣り", "食材", "漁業"]), 600)
                entry["spawning"] = spawning_from(sec)
                entry["spawningMonths"] = months_from(entry["spawning"])
                entry["seasonNote"] = season_from(sec)
                entry["seasonMonths"] = months_from(entry["seasonNote"])
                entry["sources"].append({"name": "Wikipedia 日本語版「%s」(CC BY-SA 4.0)" % ja_title, "url": url})
            # FishBase
            if entry.get("scientificName") and not sp.get("noFishBase"):
                fb = fishbase(entry["scientificName"], fb_id)
                if "maxLengthCm" in fb:
                    for k in ("maxLengthCm", "lengthType", "commonLengthCm", "maxWeightKg", "environment", "waters", "habitatType", "depthMinM", "depthMaxM", "climate", "tempMinC", "tempMaxC", "distribution", "description", "biology", "reproduction"):
                        if k in fb: entry[k] = fb[k]
                    entry["sources"].append({"name": "FishBase (Froese & Pauly, CC BY-NC 3.0)", "url": fb["url"]})
                else:
                    print("   ! FishBase なし", fb.get("error", ""))
                time.sleep(0.4)
        except Exception as ex:
            print("   ! 失敗", repr(ex)[:120]); entry["error"] = repr(ex)[:120]
        entries.append(entry)
        time.sleep(0.3)
        if n % 10 == 0:
            json.dump({"generatedAt": time.strftime("%Y-%m-%d"), "entries": entries}, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    json.dump({"generatedAt": time.strftime("%Y-%m-%d"), "entries": entries}, open(a.out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    ok = sum(1 for e in entries if e.get("scientificName")); imgs = sum(1 for e in entries if e.get("image")); fbn = sum(1 for e in entries if e.get("maxLengthCm"))
    print(f"done: {len(entries)} entries, {ok} with taxon, {imgs} images, {fbn} FishBase")

if __name__ == "__main__":
    main()
