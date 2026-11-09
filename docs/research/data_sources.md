# データ取得元の調査結果（2026-11-04）

## 1. 潮汐 — 気象庁の分潮一覧表を同梱して端末内で推算

- 気象庁は潮位表掲載地点ごとに **60分潮の振幅・遅角**（分潮一覧表）を公開している（気象庁所管の観測地点のみ）。
  - 解説: https://www.data.jma.go.jp/gmd/kaiyou/db/tide/suisan/explanation.html
  - 掲載地点一覧（年ごと。主要4分潮 M2/S2/K1/O1 は全地点、分潮一覧表へのリンクは気象庁所管地点）: https://www.data.jma.go.jp/gmd/kaiyou/db/tide/suisan/station2024.php （年の部分を差し替える）
- 推算式は海上保安庁の潮汐表と同じ調和分解：H(t) = Z0 + Σ f_i H_i cos(ω_i t + V0_i + u_i − κ_i)。ノード因子 f, u は 18.6 年周期で変わるため毎回計算する。
- 分潮一覧表がない地点（海上保安庁・国土地理院所管など）は、**潮位表テキスト版**で補う。
  - フォーマット: https://www.data.jma.go.jp/kaiyou/db/tide/suisan/readme.html
  - 1行 = 0〜23時の毎時潮位（各3桁、1〜72桁）＋年月日（73〜78桁）＋地点記号（79〜80桁）＋満潮最大4組（81〜108桁）＋干潮最大4組（109〜136桁）。改行は LF。予測なしは時刻 9999・潮位 999。
- 実装方針
  - `scripts/fetch_jma_harmonics.py` で全地点の分潮と緯度経度・基準面を取得し `data/tide/harmonics.json` に保存（年1回更新）。
  - 最寄り地点を自動選択。地点から離れた釣り場は時刻・振幅をそのまま使う（漁港レベルでは許容）。
  - 函館で推算値と気象庁潮位表の差を検証するテストを L2 に置く（目標: 数 cm・数分以内）。

## 2. 波・水温 — Open-Meteo Marine API

- エンドポイント: `https://marine-api.open-meteo.com/v1/marine?latitude=..&longitude=..&hourly=wave_height,wave_direction,wave_period,wind_wave_height,swell_wave_height,swell_wave_period,sea_surface_temperature,ocean_current_velocity`
- 無料・API キー不要・非商用利用可（本アプリは本人利用のみ）。1日 10,000 リクエストなどの上限は十分。
- 提供: 波高・向き・周期、風波とうねりの内訳、海面水温、海流。1時間値で約7日先まで（モデルは DWD 等の波浪モデル、1日2回更新）。
- 注意
  - 海上格子のため、漁港内や湾奥の座標は「陸」扱いで値が返らないことがある → 周囲を数 km の範囲で探索して最初に値が返る格子点を使い、釣り場ごとにキャッシュする。
  - データは CC BY 4.0。設定画面に「Weather data by Open-Meteo.com」とリンクを表示する。
- 見送り: 気象庁の沿岸波浪モデル・海面水温は気象業務支援センター経由の有償配信。WeatherKit は海況を提供しない。
- 参考: https://openmeteo.substack.com/p/marine-weather-forecast-api

## 3. ネット上の釣果情報 — 公開 API なし。RSS 方式に縮小

- 最大手のアングラーズ（anglers.jp）は API 非公開。2026-04-30 に運営が合同会社デイプレックスへ譲渡され仕様も流動的。スクレイピングは規約と安定性の面で採らない。
  - https://prtimes.jp/main/html/rd/p/000000106.000019379.html
- 採用する範囲（F-27、COULD）
  - 設定画面で RSS/Atom の URL を登録（釣りメディア、釣具店ブログなど）。
  - 端末で取得し、Foundation Models で「魚種・場所・日付」を抽出して釣り場カードに「最近の釣果」としてグレーで付記。
  - 釣れ率には反映しない（出典も精度も揃わないため）。
- 優先度は低い。開発者が指示したときだけ L17 で実装する。

## 5. 魚のデータと画像 — Wikidata / Wikipedia 日本語版 / Wikimedia Commons / FishBase（2026-11-09、F-60）

| 出典 | 使うもの | ライセンス・条件 | 取り方 |
| --- | --- | --- | --- |
| Wikidata | 学名（P225）・科（P171 をたどる）・FishBase ID（P938）・Commons の画像名（P18）・日本語版の記事名 | CC0 | `Special:EntityData/Q….json`（キャッシュが効く） |
| Wikipedia 日本語版 | 概要・形態・生態・分布・利用の節、産卵期・旬の文 | CC BY-SA 4.0。各種に記事名とリンクを出典として表示 | action API の `prop=revisions`（wikitext）を `mwparserfromhell` で本文化 |
| Wikimedia Commons | 種の画像 1 枚とライセンス・作者 | CC BY / CC BY-SA / CC0 / パブリックドメインの画像だけ使う（NC・ND は使わない）。作者とライセンスを画像の上と出典欄に表示 | `imageinfo` の `extmetadata`。本体は `upload.wikimedia.org` の 1000 px サムネイルを 900 px・JPEG 82 に |
| FishBase (fishbase.se) | 最大全長・よくある全長・成熟サイズ・最大体重・生息環境（海水/淡水/汽水、底生/回遊など）・水深・気候帯・水温・分布（英語）・形態と生態の短文（英語） | CC BY-NC 3.0（Froese & Pauly）。本人利用・非商用のアプリで、各種に出典として表示 | 種の要約ページ（`summary/<SpecCode>`）の本文を正規表現で読む。API（ropensci）は証明書の問題で使わない |

取り込みの流れ（2026-11-09 に「可能な限り全種」へ拡張。開発者「全国には約 4,800 種」）
1. FishBase の「日本の魚種一覧」（`country/CountryChecklist.php?c_code=392`、約 4,270 種：学名・目・科・英名・和名ローマ字・在来/移入/固有）
2. Wikidata の SPARQL（`query.wikidata.org`）で FishBase ID → QID・和名・日本語版の記事名・Commons の画像名を一括（150 件ずつ）
3. Wikipedia 日本語版の本文は **公開ダンプ**（`dumps.wikimedia.org/jawiki/latest/…multistream.xml.bz2`）から、索引で該当記事のブロックだけを Range で取る（API を 1 記事ずつ叩くと 429 で数十時間かかる）
4. FishBase の種の要約ページを 1 種ずつ（0.5 秒間隔、約 2 時間）
5. Commons の画像はライセンスを確かめて 1 枚ずつ（8 秒以上あける。数時間〜。先に手選びの 192 種、次に日本語記事のある種）
6. `scripts/build_fish_json.py` が全部を合わせて `Packages/Core/Sources/Core/Data/fish.json` を作る。和名は 手選びの名前 → Wikidata の和名 → 日本語版の記事名 → FishBase のローマ字をカタカナに直した推定名（`nameEstimated`）→ 学名 の順

スクリプト：`scripts/fetch_fish_db.py`（共通の解析・1 種ずつの取得）、`scripts/build_fish_json.py`（組み立て）、`scripts/romaji_kana.py`（ローマ字 → カタカナ）、`scripts/fish_species_list.json`（釣りの分類タグ・別名を付ける 192 種）。
Wikimedia は共有 IP への 429 が多いので、UA を名乗り、ホストごとに 1.5 秒（画像は 8 秒）あけ、`Retry-After` に従って待つ。

## 4. 気象 — WeatherKit

- Apple 公式。端末から直接取得。現在値＋時間別予報（約10日先）＋日別予報。
- 必要な設定（開発者の作業）: Apple Developer の App ID で WeatherKit capability を有効化し、Certificates, Identifiers & Profiles の Services で WeatherKit を有効にする。有効化から反映まで最大30分程度かかる。
- 月間 50 万コールまで無料。本アプリの使用量（1時間に1回＋釣果時）なら問題ない。
- 画面に Apple Weather の帰属表示（attribution）が必要。設定画面に置く。
