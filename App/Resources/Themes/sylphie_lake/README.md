# sylphie_lake — シルフィ 海図（夕映えの湖）

海図の 1 画面（F-63、`"screen": "chart"`）を、開発者の絵（夕暮れの湖畔のシルフィ）で着せ替えたテーマ。予想図は `docs/ui/sylphie_lake_preview.jpg`。
港の海図（`App/Resources/Charts/`）は標準の海図と同じものを使う。

| ファイル | 内容 | 作り方 |
| --- | --- | --- |
| `chart_bg_idle.jpg` | 待機中の背景（1206×2683）。開発者の絵そのまま＋上に空と木の続き | 上の 540 行だけ Gemini `gemini-3-pro-image-preview` で描き足し、元の絵を継ぎ目をぼかして重ねた（人物は元の絵のまま） |
| `chart_orb_start.png` | 開始ボタン（銀の蔦の縁、深緑の面。文字はアプリ） | pro、マゼンタ背景 → `scripts/theme_chroma_key.py` |
| `chart_orb_shutter.png` | 撮影ボタン（夕日の琥珀に、葉の形の絞り） | 同上 |
| `chart_dial.png` | 風向の計器（銀の目盛り、上に金の葉＝北。針はアプリ） | 同上 |
| `chart_corner.png` | 地図とメニューの枠の角飾り（左上向き。アプリが鏡映しで四隅へ） | 同上。房のところだけ切り出し、線の先を消えるように |
| `chart_menu_*.png` | メニューの印 6 つ（ログ・図鑑・釣り場・釣果情報・相談・設定） | pro で 1 枚に 6 つ描かせて切り分け（巻物の封蝋の文字だけ描き直し） |
| `bg_sheet.jpg` `bg_detail.jpg` `bg_log.jpg` `bg_guide.jpg` `bg_spots.jpg` | 「≡」から開く画面の背景（人物なしの夜の湖畔） | `gemini-3.1-flash-image`（ログだけ pro） |
| `thumb.jpg` | 設定 > テーマ のカードの絵 | 予想図から |

`theme.json` の `chart`：色（深い森の緑・生成りの白・夕日の金・湖の水色・銀の縁）、明朝の数字、待機中は数字を空へ寄せて顔を見せる配置（`idleFaceGap`）、光の粒、地図の額（`mapFrame`）、札のメニュー（`menu: "panel"`）。書き方は `docs/07_theme_spec.md` §4。
