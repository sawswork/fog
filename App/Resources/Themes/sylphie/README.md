# sylphie — 森の魔法陣（F-58）

タブバーも下の 5 つのボタンも無い、1 枚で完結するホーム。画像は Gemini（`gemini-3-pro-image-preview`、OpenAI 互換の images エンドポイント）で生成し、
マゼンタ背景を `scripts/theme_chroma_key.py` で透過 PNG にしてある（2026-11-09）。

| ファイル | 内容 | 置き方 |
| --- | --- | --- |
| `bg_home.jpg` | 夜の森・満月・光の粒・百合（縦 9:16、768×1376） | 全画面に `fill`、`motion: drift`（ゆっくり寄って戻る） |
| `ring_home.png` | 釣れ率の後ろの魔法陣（透過・中央は空） | 上部中央（幅 72%）に `fit`、`motion: spin`（1 周 100 秒） |
| `char_home.png` | シルフィ（短い白髪・赤い瞳・黒のリブタートル・白いジャケット、透過） | 中央（幅 76%・高さ 58%）に `fit`、`motion: float`（上下にふわり） |
| `map_frame.png` | 下の地図に重ねる光の枠と百合（透過） | 下部に `fit` |
| `tab_camera.png` / `tab_guide.png` | 撮影・図鑑のボタンの印（透過） | `button` 部品の画像 |
| `bg_log.jpg` `bg_guide.jpg` `bg_sheet.jpg` | 他の画面の背景 | 従来どおり |

効果の層（画像なし）：`fireflies`（光の粒 34）、`sparkles`（きらめき 14、金）、`leaves`（舞う葉 9）。書き方は `docs/07_theme_spec.md` の「動き・効果」。

画面の行き来：ログは直近の釣果の写真、釣り場は下の地図、図鑑と撮影は右中段のボタン、設定・相談・月は上の見出し。
