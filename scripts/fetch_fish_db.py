#!/usr/bin/env python3
"""全国の釣り魚データベース（図鑑 F-60）を信頼できる出典から集める。

出典
- Wikidata: 学名・分類・FishBase ID・Commons の画像名（CC0）
- Wikimedia Commons: 画像本体とライセンス・作者（CC BY / CC BY-SA / CC0 / パブリックドメインのものだけ使う）
- Wikipedia 日本語版: 解説（形態・生態・分布・利用）。CC BY-SA 4.0、出典として記事名を記録
- FishBase (fishbase.se): 最大全長・一般的な全長・生息環境・水深・水温・分布。CC BY-NC 3.0、出典として記録

使い方: python3 scripts/fetch_fish_db.py --out Packages/Core/Sources/Core/Resources/Data/fish.json --images App/Resources/Fish [--only アイナメ,クロソイ] [--limit N]
依存: requests, Pillow, mwparserfromhell
"""
import argparse, json, os, re, sys, time, io, html
import requests
from PIL import Image

UA = "FogFishGuide/1.0 (personal fishing app, https://github.com/sawswork/fog)"
_S = requests.Session(); _S.headers["User-Agent"] = UA
_last = {}

class _Throttled:
    """Wikimedia の礼儀（ホストごとに直列・1.5 秒に 1 回まで）と 429 の待ち直し"""
    def get(self, url, **kw):
        host = url.split("/")[2]
        if "fishbase" in host:
            return _S.get(url, **kw)
        # 画像の配信元（upload）はロボット方針が厳しいので 1 枚ごとに十分あける
        interval = 8.0 if host.startswith("upload.") else 1.5
        for attempt in range(8):
            wait = max(0.0, interval - (time.time() - _last.get(host, 0.0)))
            if wait > 0: time.sleep(wait)
            _last[host] = time.time()
            r = _S.get(url, **kw)
            if r.status_code == 429 or r.status_code >= 500:
                ra = r.headers.get("Retry-After")
                delay = max(float(ra) if ra and ra.isdigit() else 0.0, 30.0 * (attempt + 1))
                print(f"   … {r.status_code} {host}、{delay:.0f} 秒待つ", flush=True); time.sleep(min(delay, 180)); continue
            return r
        return r
S = _Throttled()
HERE = os.path.dirname(os.path.abspath(__file__))
OK_LICENSES = ("CC BY-SA", "CC BY ", "CC BY-", "CC0", "Public domain", "CC-BY", "cc-by", "pd", "PD", "Attribution")

def wiki_page(title):
    """jawiki の action API 1 回で QID・本文（wikitext）・正式な記事名を取る（リダイレクト解決）"""
    r = S.get("https://ja.wikipedia.org/w/api.php", params={"action": "query", "prop": "pageprops|revisions", "ppprop": "wikibase_item", "rvprop": "content", "rvslots": "main",
                                                         "titles": title, "redirects": 1, "format": "json", "formatversion": 2}, timeout=40)
    if r.status_code != 200: return None
    pages = r.json().get("query", {}).get("pages", [])
    for p in pages:
        if p.get("missing"): return None
        wt = ((p.get("revisions") or [{}])[0].get("slots", {}).get("main", {}).get("content")) or ""
        if "#転送" in wt[:20].upper() or wt[:9].upper() == "#REDIRECT": return None
        return {"title": p.get("title"), "qid": p.get("pageprops", {}).get("wikibase_item"), "wikitext": wt}
    return None

def taxobox_sciname(wt):
    """生物分類表の |学名 = から「属 種」を取る（{{Snamei|…}} や '' を剥がす）"""
    m = re.search(r"\|\s*学名\s*=\s*(.{0,120})", wt or "")
    if not m: return None
    v = re.sub(r"\{\{[Ss]namei\|+([^}|]+)[^}]*\}\}", r"\1", m.group(1))
    v = re.sub(r"<[^>]+>|''|\[\[|\]\]|\{\{|\}\}", "", v)
    m2 = re.search(r"\b([A-Z][a-z]+)\s+([a-z]+)", v)
    return f"{m2.group(1)} {m2.group(2)}" if m2 else None

def taxobox_family(wt):
    m = re.search(r"\|\s*科\s*=\s*\[\[([^\]|]+)(?:\|[^\]]*)?\]\]", wt or "")
    if m: return m.group(1).strip()
    m = re.search(r"\|\s*科\s*=\s*([^\n|<{]+)", wt or "")
    return m.group(1).strip() if m and m.group(1).strip() else None

def rest_summary(title):
    """Wikipedia 日本語版の REST summary：リダイレクト解決・QID・要約。キャッシュが効くので action API より遠慮なく呼べる"""
    r = S.get("https://ja.wikipedia.org/api/rest_v1/page/summary/" + requests.utils.quote(title, safe=""), timeout=30, headers={"Accept": "application/json"})
    if r.status_code != 200: return None
    return r.json()

def entity_data(qid):
    r = S.get(f"https://www.wikidata.org/wiki/Special:EntityData/{qid}.json", timeout=30)
    r.raise_for_status()
    return r.json().get("entities", {}).get(qid, {})

def raw_wikitext(title):
    r = S.get("https://ja.wikipedia.org/w/index.php", params={"title": title, "action": "raw"}, timeout=30)
    if r.status_code != 200: return ""
    return r.text

def wikitext_to_plain(wt):
    import mwparserfromhell as mw
    # 見出しは strip で消えるので印に置き換えてから
    wt = re.sub(r"^(=+)\s*(.+?)\s*\1\s*$", lambda m: "\n§§" + m.group(2).strip() + "§§\n", wt, flags=re.M)
    code = mw.parse(wt)
    # 表・ファイル・参照・テンプレートを落とす
    for t in list(code.filter_templates(recursive=False)):
        try: code.remove(t)
        except Exception: pass
    for tag in list(code.filter_tags(recursive=True)):
        if tag.tag.lower() in ("ref", "gallery", "table", "imagemap", "timeline"):
            try: code.remove(tag)
            except Exception: pass
    for wl in list(code.filter_wikilinks(recursive=True)):
        if str(wl.title).lower().startswith(("file:", "ファイル:", "image:", "画像:", "category:", "カテゴリ:")):
            try: code.remove(wl)
            except Exception: pass
    text = code.strip_code(normalize=True, collapse=True)
    text = re.sub(r"\{\|.*?\|\}", "", text, flags=re.S)
    text = re.sub(r"\[\[(?:[^\]|]*\|)?([^\]]*)\]\]", r"\1", text)
    text = re.sub(r"§§(.+?)§§", r"\n== \1 ==\n", text)
    return text

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

def taxon_via_wikipedia(name):
    pg = wiki_page(name)
    if not pg or "{{aimai" in (pg.get("wikitext") or "").lower() or "{{曖昧さ回避" in (pg.get("wikitext") or ""): return None, None
    qid = pg.get("qid")
    if not qid: return None, pg
    e = entity_data(qid)
    if not claim(e, "P225"):
        return None, pg
    return e, pg

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
        u = ii.get("thumburl") or ii.get("url") or ""
        u = u.replace("https://thumb.wikimedia.org/", "https://upload.wikimedia.org/").split("?")[0]
        return {"url": u, "license": lic, "licenseURL": g("LicenseUrl"), "artist": g("Artist")[:120], "credit": g("Credit")[:120],
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
    seg = re.search(r"Environment: milieu / climate zone / depth range / distribution range\s*Ecology\s*(.*?)\s*Distribution\s+(?:Countries|Territories)", t)
    if seg:
        s = seg.group(1)
        out["environment"] = re.sub(r"\(Ref\.[^)]*\)", "", s).strip()[:200]
        out["waters"] = [w for w in ("Marine", "Freshwater", "Brackish") if re.search(r"\b" + w.lower() + r"\b", s.lower())]
        h = re.search(r"(bathydemersal|bathypelagic|benthopelagic|demersal|pelagic-neritic|pelagic-oceanic|reef-associated|pelagic)", s)
        if h: out["habitatType"] = h.group(1)
        d = re.search(r"depth range\s*(\d+)\s*-\s*(\d+)\s*m", s)
        if d: out["depthMinM"] = int(d.group(1)); out["depthMaxM"] = int(d.group(2))
        else:
            d = re.search(r"depth range\s*\?\s*-\s*(\d+)\s*m", s)
            if d: out["depthMaxM"] = int(d.group(1))
        c = re.search(r"(Tropical|Subtropical|Temperate|Boreal|Polar|Deep-water)\s*;?\s*(?:([\d.]+)\s*°C\s*-\s*([\d.]+)\s*°C)?", s)
        if c:
            out["climate"] = c.group(1)
            if c.group(2): out["tempMinC"] = float(c.group(2)); out["tempMaxC"] = float(c.group(3))
        if re.search(r"anadromous", s): out["migration"] = "anadromous"
        elif re.search(r"catadromous", s): out["migration"] = "catadromous"
        elif re.search(r"oceanodromous", s): out["migration"] = "oceanodromous"
        elif re.search(r"amphidromous", s): out["migration"] = "amphidromous"
    m = re.search(r"Distribution\s+(?:Countries|Territories)\s*\|\s*FAO areas\s*\|\s*Ecosystems\s*\|\s*Occurrences\s*\|\s*Point map\s*\|\s*Introductions\s*\|\s*Faunafri\s*(.*?)(?:Length at first maturity|Size / Weight / Age)", t)
    if m: out["distribution"] = re.sub(r"\(Ref\.[^)]*\)", "", m.group(1)).strip()[:400]
    m = re.search(r"Maturity:\s*L\s*m\s*([\d.]+)", t)
    if m: out["maturityLengthCm"] = float(m.group(1))
    m = re.search(r"Short description\s+Identification keys \| Morphology \| Morphometrics\s*(.*?)\s*Biology\s+Glossary", t)
    if m and len(m.group(1).strip()) > 3: out["description"] = re.sub(r"\(Ref\.[^)]*\)", "", m.group(1)).strip()[:500]
    m = re.search(r"Biology\s+Glossary\s*\(e\.g\. epibenthic\)\s*(.*?)(?:Life cycle and mating behavior|IUCN Red List Status)", t)
    if m: out["biology"] = re.sub(r"\(Ref\.\s*[^)]*\)", "", re.sub(r"Minimum depth from Ref\. \d+ \.", "", m.group(1))).strip()[:700]
    m = re.search(r"Life cycle and mating behavior\s+Maturity \| Reproduction \| Spawning \| Eggs \| Fecundity \| Larvae\s*(.*?)(?:Main reference|IUCN)", t)
    if m and len(m.group(1).strip()) > 10: out["reproduction"] = m.group(1).strip()[:400]
    return out

MONTHS = {"1": 1, "一": 1, "2": 2, "二": 2, "3": 3, "三": 3, "4": 4, "四": 4, "5": 5, "五": 5, "6": 6, "六": 6, "7": 7, "七": 7, "8": 8, "八": 8, "9": 9, "九": 9, "10": 10, "十": 10, "11": 11, "十一": 11, "12": 12, "十二": 12}
SEASON_MONTHS = {"春": [3, 4, 5], "夏": [6, 7, 8], "秋": [9, 10, 11], "冬": [12, 1, 2], "初夏": [5, 6], "晩秋": [10, 11], "初春": [2, 3], "晩夏": [8, 9], "初冬": [11, 12], "真冬": [1, 2], "早春": [2, 3], "梅雨": [6]}

def months_from(text):
    """「産卵期は4-6月」「春から初夏」などから月の集合を取る"""
    if not text: return []
    out = set()
    for m in re.finditer(r"(\d{1,2})\s*(?:月)?\s*(?:[-〜～–-]|から|乃至|ないし)\s*(\d{1,2})\s*月", text):
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

def lengths_from(text):
    """Wikipedia の本文から「全長 30-40 cm」「最大 120 cm」「1 m に達する」などを拾う → (max, typical)"""
    if not text: return (None, None)
    t = text.replace("センチメートル", "cm").replace("センチ", "cm").replace("メートル", "m").replace("〜", "-").replace("～", "-").replace("–", "-")
    t = re.sub(r"（\s*(?:cm|m)\s*）", "", t)
    U = r"(cm|m)(?![a-zA-Z])"
    def num(x, unit):
        v = float(x); return v * 100 if unit == "m" else v
    mx = None; typ = None
    for m in re.finditer(r"最大(?:で|では|級は|サイズは)?(?:全長|体長|胴長|長さ)?(?:は|が)?約?\s*([\d.]+)\s*" + U, t):
        mx = max(mx or 0, num(m.group(1), m.group(2)))
    for m in re.finditer(r"([\d.]+)\s*" + U + r"(?:を超える|に達する|にもなる|以上になる|に成長する|を超す|に及ぶ)", t):
        mx = max(mx or 0, num(m.group(1), m.group(2)))
    m = re.search(r"(?:全長|体長|胴長)(?:は|が)?約?\s*([\d.]+)\s*-\s*([\d.]+)\s*" + U, t)
    if m:
        a, b = num(m.group(1), m.group(3)), num(m.group(2), m.group(3))
        typ = (a + b) / 2
        if mx is None: mx = b
    else:
        m = re.search(r"(?:全長|体長|胴長)(?:は|が)?約?\s*([\d.]+)\s*" + U + r"\s*(?:ほど|程度|前後|くらい)", t)
        if m: typ = num(m.group(1), m.group(2))
        else:
            m = re.search(r"(?:全長|体長|胴長)(?:は|が)?約?\s*([\d.]+)\s*" + U, t)
            if m and mx is None: mx = num(m.group(1), m.group(2))
    if mx is not None and (mx < 2 or mx > 2000): mx = None
    if typ is not None and (typ < 1 or typ > 2000): typ = None
    if mx is not None and typ is not None and typ > mx: mx = typ
    return (mx, typ)

def spawning_from(sec):
    for k in ("生態", "繁殖", "産卵", "生活史"):
        t = find_section(sec, [k])
        m = re.search(r"産卵[期時][^。]{0,60}", t or "")
        if m: return m.group(0)
    t = sec.get("lead", "")
    m = re.search(r"産卵[期時][^。]{0,60}", t)
    return m.group(0) if m else ""

def season_from(sec):
    """「旬は冬」「晩秋から春にかけてが旬」などの一文"""
    texts = [find_section(sec, [k]) for k in ("人間", "利用", "釣り", "漁業", "食", "料理")] + [sec.get("lead", "")]
    for t in texts:
        if not t: continue
        m = re.search(r"旬は[^。」]{1,40}", t) or re.search(r"[^。「」]{1,40}(?:が|を)旬[^。」]{0,20}", t) or re.search(r"[^。「」]{1,40}旬[^。」]{1,30}", t)
        if m and re.search(r"[春夏秋冬月]", m.group(0)): return m.group(0).strip("「」 ")
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
            e, sm = taxon_via_wikipedia(sp.get("wikipedia") or name)
            if e is None:
                for alt in [sp.get("wikidata")] + sp.get("aliases", []):
                    if alt:
                        e, sm = taxon_via_wikipedia(alt)
                        if e is not None: break
            if e is None:
                e = pick_taxon(sp.get("wikidata") or name, sp.get("aliases", []))
            if e is None:
                print("   ! Wikidata で見つからず"); entry["missing"] = True; entries.append(entry); continue
            entry["wikidata"] = e["id"]
            entry["scientificName"] = claim(e, "P225")
            en = e.get("labels", {}).get("en", {}).get("value")
            if en and en != entry["scientificName"]: entry["englishName"] = en
            fb_id = claim(e, "P938")
            ja_title = e.get("sitelinks", {}).get("jawiki", {}).get("title") or (sm or {}).get("title")
            wikitext_cached = (sm or {}).get("wikitext") if sm and (sm.get("title") == ja_title) else None
            fam_tb = taxobox_family(wikitext_cached)
            # 分類（科）：親をたどる（最大 4 段）
            parent = claim(e, "P171"); fam = fam_tb
            for _ in range(0 if fam else 5):
                if not isinstance(parent, dict): break
                pe = entity_data(parent["id"])
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
                url = "https://ja.wikipedia.org/wiki/" + requests.utils.quote(ja_title, safe="")
                wt = wikitext_cached or raw_wikitext(ja_title)
                text = wikitext_to_plain(wt) if wt else ""
                if not text:
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
                    for k in ("maxLengthCm", "lengthType", "commonLengthCm", "maxWeightKg", "maturityLengthCm", "environment", "waters", "habitatType", "migration", "depthMinM", "depthMaxM", "climate", "tempMinC", "tempMaxC", "distribution", "description", "biology", "reproduction"):
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
