#!/usr/bin/env python3
"""気象庁「潮位表掲載地点一覧表」と各地点の「分潮一覧表」を取得し、Core 同梱用の harmonics.json を作る。

  python3 scripts/fetch_jma_harmonics.py --year 2026 --out data/tide/harmonics.json \
      --core-data Packages/Core/Sources/Core/Data/harmonics.json \
      --fixture-dir Packages/Core/Tests/CoreTests/Fixtures --fixture-stations 函館

- 一覧: https://www.data.jma.go.jp/kaiyou/db/tide/suisan/station{year}.php
- 分潮一覧表: 一覧ページの各地点行にあるリンク（気象庁所管地点のみ）
- 潮位表テキスト: https://www.data.jma.go.jp/kaiyou/data/db/tide/suisan/txt/{year}/{code}.txt（検証用フィクスチャ）

標準ライブラリのみ。Claude Code の実行環境からは気象庁に届かないため、CI（.github/workflows/tide-data.yml）で実行する。
ページ構造が変わって解析できないときは診断情報を出して失敗する。
"""

import argparse
import html
import json
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

BASES = ["https://www.data.jma.go.jp/kaiyou/db/tide/suisan/", "https://www.data.jma.go.jp/gmd/kaiyou/db/tide/suisan/"]
TXT_BASES = ["https://www.data.jma.go.jp/kaiyou/data/db/tide/suisan/txt/", "https://www.data.jma.go.jp/gmd/kaiyou/data/db/tide/suisan/txt/"]

CONSTITUENT_ALIASES = {
    "SIG1": "σ1", "SIGMA1": "σ1", "RHO1": "ρ1", "PI1": "π1", "PSI1": "ψ1", "PHI1": "φ1", "FI1": "φ1",
    "THE1": "θ1", "THETA1": "θ1", "CHI1": "χ1", "LAM2": "λ2", "LAMBDA2": "λ2", "MU2": "μ2", "2MS2": "μ2", "NU2": "ν2",
    "SA": "Sa", "SSA": "Ssa", "MM": "Mm", "MSF": "MSf", "MF": "Mf",
}
KNOWN = {"Sa", "Ssa", "Mm", "MSf", "Mf", "2Q1", "σ1", "Q1", "ρ1", "O1", "MP1", "M1", "χ1", "π1", "P1", "S1", "K1", "ψ1", "φ1",
         "θ1", "J1", "SO1", "OO1", "OQ2", "MNS2", "2N2", "μ2", "N2", "ν2", "OP2", "M2", "MKS2", "λ2", "L2", "T2", "S2", "R2",
         "K2", "MSN2", "KJ2", "2SM2", "MO3", "M3", "SO3", "MK3", "SK3", "MN4", "M4", "SN4", "MS4", "MK4", "S4", "SK4",
         "2MN6", "M6", "MSN6", "2MS6", "2MK6", "2SM6", "MSK6", "M8", "MS8"}


def log(msg):
    print(msg, file=sys.stderr, flush=True)


def canonical(name):
    s = name.strip().replace(" ", "").replace("　", "")
    if s in KNOWN:
        return s
    u = s.upper()
    if u in CONSTITUENT_ALIASES:
        return CONSTITUENT_ALIASES[u]
    for k in KNOWN:
        if k.upper() == u:
            return k
    return None


def fetch(url, retries=3):
    last = None
    for i in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "fog-tide-data/1.0 (+https://github.com/sawswork/fog)"})
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                ctype = r.headers.get("Content-Type", "")
            m = re.search(r"charset=([\w-]+)", ctype, re.I)
            encodings = [m.group(1)] if m else []
            head = raw[:4000].decode("ascii", "ignore")
            m2 = re.search(r"charset=[\"']?([\w-]+)", head, re.I)
            if m2:
                encodings.append(m2.group(1))
            encodings += ["utf-8", "cp932", "euc-jp"]
            for enc in encodings:
                try:
                    return raw.decode(enc)
                except Exception:
                    continue
            return raw.decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            last = e
            if e.code == 404:
                raise
        except Exception as e:  # noqa: BLE001
            last = e
        time.sleep(2 * (i + 1))
    raise RuntimeError(f"fetch failed: {url}: {last}")


class TableParser(HTMLParser):
    """<table> を行×セルの文字列と、セル内リンクに分解する。"""

    def __init__(self):
        super().__init__()
        self.tables = []
        self._row = None
        self._cell = None
        self._links = None
        self._href = None
        self.all_links = []

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "table":
            self.tables.append([])
        elif tag == "tr":
            self._row = []
        elif tag in ("td", "th"):
            self._cell = []
            self._links = []
        elif tag == "a" and "href" in a:
            self._href = a["href"]
            self.all_links.append((a["href"], ""))
            if self._links is not None:
                self._links.append([a["href"], ""])

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self._row is not None and self._cell is not None:
            text = html.unescape("".join(self._cell)).strip()
            self._row.append({"text": re.sub(r"\s+", " ", text), "links": [(h, t.strip()) for h, t in (self._links or [])]})
            self._cell = None
            self._links = None
        elif tag == "tr" and self._row is not None:
            if self.tables:
                self.tables[-1].append(self._row)
            self._row = None
        elif tag == "a":
            self._href = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell.append(data)
        if self._href is not None:
            if self.all_links:
                h, t = self.all_links[-1]
                self.all_links[-1] = (h, t + data)
            if self._links:
                self._links[-1][1] += data


DEG_RE = re.compile(r"(\d{1,3})\s*[°゜度]\s*(\d{1,2}(?:\.\d+)?)\s*[′'分]?")
DEC_RE = re.compile(r"^-?\d{1,3}\.\d+$")


def parse_angle(text):
    m = DEG_RE.search(text)
    if m:
        return int(m.group(1)) + float(m.group(2)) / 60
    t = text.strip()
    if DEC_RE.match(t):
        return float(t)
    return None


def parse_station_list(page_html, base_url):
    p = TableParser()
    p.feed(page_html)
    stations = []
    for table in p.tables:
        for row in table:
            cells = [c["text"] for c in row]
            if len(cells) < 4:
                continue
            # 行: 番号, 記号(英字を含む2文字), 名前, 緯度(44゜21'), 経度(143゜22'), 平均水面(cm), ..., M2 振幅 遅角, S2, K1, O1
            code = next((c for c in cells if re.fullmatch(r"[A-Z0-9]{2}", c) and re.search(r"[A-Z]", c)), None)
            deg_cells = [(i, parse_angle(c)) for i, c in enumerate(cells) if DEG_RE.search(c)]
            if not code or len(deg_cells) < 2:
                continue
            lat = next((a for _, a in deg_cells if a is not None and 20 <= a <= 46), None)
            lon = next((a for _, a in deg_cells if a is not None and 122 <= a <= 154), None)
            if lat is None or lon is None:
                continue
            lon_index = max(i for i, _ in deg_cells)
            z0_from_list = None
            if lon_index + 1 < len(cells) and re.fullmatch(r"-?\d+(\.\d+)?", cells[lon_index + 1].strip()):
                z0_from_list = float(cells[lon_index + 1])
            name = next((c for c in cells if re.search(r"[぀-ヿ一-鿿]", c) and len(c) <= 12), "")
            links = [(urllib.parse.urljoin(base_url, h), t) for c in row for h, t in c["links"]]
            harmonics = [h for h, t in links if "分潮" in t or "harms" in h.lower() or "bunchou" in h.lower()]
            tide = [h for h, t in links if "潮位表" in t or "/txt/" in h or "suisan" in h.lower() and h.endswith(".txt")]
            # 主要4分潮（M2,S2,K1,O1 の振幅・遅角）が並ぶ数値列を拾う
            numeric = []
            for c in cells:
                t = c.replace(",", "")
                if re.fullmatch(r"-?\d+(\.\d+)?", t):
                    numeric.append(float(t))
            stations.append({
                "id": code, "name": name, "latitude": lat, "longitude": lon,
                "harmonicsURL": harmonics[0] if harmonics else None,
                "tideURL": tide[0] if tide else None,
                "numeric": numeric, "cells": cells, "z0FromList": z0_from_list,
            })
    return stations, p


SPEEDS = {'Sa': 0.0410686, 'Ssa': 0.0821373, 'Mm': 0.5443747, 'MSf': 1.0158958, 'Mf': 1.0980331, '2Q1': 12.8542862,
          'σ1': 12.9271398, 'Q1': 13.3986609, 'ρ1': 13.4715145, 'O1': 13.9430356, 'MP1': 14.0251729, 'M1': 14.4920521,
          'χ1': 14.5695476, 'π1': 14.9178647, 'P1': 14.9589314, 'S1': 15.0, 'K1': 15.0410686, 'ψ1': 15.0821353,
          'φ1': 15.1232059, 'θ1': 15.5125897, 'J1': 15.5854433, 'SO1': 16.0569644, 'OO1': 16.1391017, 'OQ2': 27.3416965,
          'MNS2': 27.4238337, '2N2': 27.8953548, 'μ2': 27.9682084, 'N2': 28.4397295, 'ν2': 28.5125831, 'OP2': 28.9019669,
          'M2': 28.9841042, 'MKS2': 29.0662415, 'λ2': 29.4556253, 'L2': 29.5284789, 'T2': 29.9589333, 'S2': 30.0,
          'R2': 30.0410667, 'K2': 30.0821373, 'MSN2': 30.5443747, 'KJ2': 30.626512, '2SM2': 31.0158958, 'MO3': 42.9271398,
          'M3': 43.4761563, 'SO3': 43.9430356, 'MK3': 44.0251729, 'SK3': 45.0410686, 'MN4': 57.4238337, 'M4': 57.9682084,
          'SN4': 58.4397295, 'MS4': 58.9841042, 'MK4': 59.0662415, 'S4': 60.0, 'SK4': 60.0821373, '2MN6': 86.407938,
          'M6': 86.9523127, 'MSN6': 87.4238337, '2MS6': 87.9682084, '2MK6': 88.0503457, '2SM6': 88.9841042, 'MSK6': 89.0662415,
          'M8': 115.9364169, 'MS8': 116.9523127}

TRIPLE_RE = re.compile(r"(\d+\.\d{6,7})\s+(-?\d+\.\d+)\s+(-?\d+\.\d+)")
LON_RE = re.compile(r"経度\s*(\d{1,3})\s*度\s*(\d{1,2})\s*分\s*(\d{1,2}(?:\.\d+)?)?\s*秒?")


def name_for_speed(speed):
    best = min(SPEEDS.items(), key=lambda kv: abs(kv[1] - speed))
    return best[0] if abs(best[1] - speed) < 2e-4 else None


def parse_harmonics_page(page_html):
    """分潮一覧表ページ → (Z0 or None, 経度 or None, [(name, amp_cm, phase_deg)])。
    行は「記号 (日本語名) 速度(度/時) 振幅(cm) 遅角(°)」。記号の表記ゆれを避け、速度で分潮を同定する。
    遅角は現地子午線基準（ページの注記）。"""
    text = re.sub(r"<[^>]+>", " ", page_html)
    text = html.unescape(text)
    text = re.sub(r"\s+", " ", text)
    constituents = {}
    for m in TRIPLE_RE.finditer(text):
        speed, amp, ph = float(m.group(1)), float(m.group(2)), float(m.group(3))
        name = name_for_speed(speed)
        if name is None:
            log(f"::warning::未知の速度 {speed} を無視")
            continue
        constituents[name] = (amp, ph % 360)
    z0 = None
    mz = re.search(r"(平均水面|Z0|Ｚ０)[^0-9-]{0,20}(-?\d+(?:\.\d+)?)", text)
    if mz:
        z0 = float(mz.group(2))
    lon = None
    ml = LON_RE.search(text)
    if ml:
        lon = int(ml.group(1)) + int(ml.group(2)) / 60 + (float(ml.group(3)) if ml.group(3) else 0) / 3600
    return z0, lon, [(n, a, p_) for n, (a, p_) in constituents.items()]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--year", type=int, required=True)
    ap.add_argument("--out", default="data/tide/harmonics.json")
    ap.add_argument("--core-data", default=None, help="Core 同梱用にも書き出す")
    ap.add_argument("--fixture-dir", default=None)
    ap.add_argument("--fixture-stations", nargs="*", default=[])
    ap.add_argument("--limit", type=int, default=0, help="デバッグ用：先頭 N 地点だけ")
    args = ap.parse_args()

    page = None
    list_url = None
    for base in BASES:
        for name in (f"station{args.year}.php", "station.php"):
            url = base + name
            try:
                page = fetch(url)
                list_url = url
                break
            except Exception as e:  # noqa: BLE001
                log(f"list fetch failed: {url}: {e}")
        if page:
            break
    if not page:
        log("::error::地点一覧ページを取得できません")
        return 1
    log(f"list page: {list_url} ({len(page)} chars)")

    stations, parser = parse_station_list(page, list_url)
    log(f"parsed station rows: {len(stations)}")
    if not stations:
        log("::error::地点行を解析できません。診断:")
        for t_i, table in enumerate(parser.tables[:5]):
            for row in table[:4]:
                log(f"  table{t_i} row: {[c['text'][:20] for c in row][:12]}")
        hrefs = sorted({h for h, _ in parser.all_links})
        for h in hrefs[:40]:
            log(f"  link: {h}")
        return 1
    with_h = [s for s in stations if s["harmonicsURL"]]
    log(f"stations with harmonics link: {len(with_h)}")
    if not with_h:
        log("::warning::分潮一覧表へのリンクが見つかりません。診断:")
        for s in stations[:3]:
            log(f"  row: {s['cells'][:14]}")
        hrefs = sorted({h for h, _ in parser.all_links})
        for h in hrefs[:60]:
            log(f"  link: {h}")

    out_stations = []
    count = 0
    for s in stations:
        if args.limit and count >= args.limit:
            break
        count += 1
        constituents = []
        z0 = None
        page_lon = None
        if s["harmonicsURL"]:
            try:
                hp = fetch(s["harmonicsURL"])
                z0, page_lon, cons = parse_harmonics_page(hp)
                constituents = [{"name": n, "amplitudeCm": a, "phaseLagDeg": p_} for n, a, p_ in cons]
                if len(cons) < 10 or count == 1:
                    if len(cons) < 10:
                        log(f"::warning::{s['name']}({s['id']}): 分潮 {len(cons)} 個しか解析できず: {s['harmonicsURL']}")
                    snippet = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", hp)))
                    idx = snippet.find("60分潮")
                    log(f"  {s['name']}: z0={z0} lon={page_lon} cons={len(cons)} snippet: {snippet[max(0, idx - 300):idx + 200]} ... {snippet[-500:]}")
                time.sleep(0.3)
            except Exception as e:  # noqa: BLE001
                log(f"::warning::{s['name']}({s['id']}): 分潮ページ取得失敗 {e}")
        if z0 is None:
            z0 = s.get("z0FromList") or 0.0
        # 遅角は現地子午線基準：推算側で V_G + 種別 × 経度 にする（分潮一覧表に書かれた経度を優先）
        lon_for_phase = page_lon if page_lon is not None else s["longitude"]
        out_stations.append({
            "id": s["id"], "name": s["name"],
            "coordinate": {"latitude": round(s["latitude"], 5), "longitude": round(s["longitude"], 5)},
            "meanSeaLevelCm": z0,
            "constituents": constituents,
            "lagLongitudeDeg": round(lon_for_phase, 5),
        })

    result = {"year": args.year, "source": list_url, "stations": out_stations}
    for path in [args.out] + ([args.core_data] if args.core_data else []):
        with open(path, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, separators=(",", ":"))
            f.write("\n")
        log(f"wrote {path}: {len(out_stations)} stations, {sum(1 for s in out_stations if s['constituents'])} with harmonics")

    # 検証用の潮位表テキスト
    if args.fixture_dir and args.fixture_stations:
        for want in args.fixture_stations:
            st = next((s for s in stations if want in s["name"]), None)
            if not st:
                log(f"::warning::フィクスチャ地点 {want} が一覧にありません")
                continue
            got = False
            for base in TXT_BASES:
                url = f"{base}{args.year}/{st['id']}.txt"
                try:
                    txt = fetch(url)
                    path = f"{args.fixture_dir}/jma_tide_{st['id']}_{args.year}.txt"
                    with open(path, "w", encoding="utf-8", newline="\n") as f:
                        f.write(txt)
                    log(f"wrote fixture {path} ({len(txt.splitlines())} lines) from {url}")
                    got = True
                    break
                except Exception as e:  # noqa: BLE001
                    log(f"tide txt fetch failed: {url}: {e}")
            if not got and st.get("tideURL"):
                log(f"  一覧のリンク: {st['tideURL']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
