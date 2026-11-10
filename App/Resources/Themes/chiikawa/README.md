# chiikawa — 星空のテント（F-58、2026-11-10）

開発者が添付した絵（星空・紙飛行機の 3 人・毛布のテント）をもとにしたテーマ。**標準レイアウト**のまま、配色・丸い書体・輪郭線・画像で見た目を変える（`home` の配置は持たない）。
画像はすべて Gemini `gemini-3-pro-image-preview` に添付の絵を参考画像として渡して生成した（2K）。本人利用のみのアプリ内で使う。

| ファイル | 内容 |
| --- | --- |
| `bg_home.jpg` | ホームの背景。上は星空・流れ星・3 人の星座、下は毛布のテントの中（予報カードがテントに収まる）。キャラクターと月は描かない |
| `char_home.png` + `char_home.json` | 釣れ率の円の左右の 3 人（左に紙飛行機のちいかわとハチワレ、右にうさぎ）。`cx` `cy` `d` は画像の中の円の位置と大きさ。`d` を大きくするとキャラクターが小さくなる |
| `ring_home.png` | 円に沿う旗と星の飾り枠 |
| `bg_log.jpg` / `bg_guide.jpg` / `bg_spots.jpg` / `bg_sheet.jpg` / `bg_detail.jpg` | 各画面の背景（ガーランドの夜空、星座、流れ星と雲、静かな夜空） |
| `char_log.png` / `char_guide.png` / `char_spots.png` | ログのハチワレ（日記帳）、図鑑のうさぎ（懐中電灯）、地図のちいかわ（くまのぬいぐるみ） |
| `tabbar.jpg` | タブバーの帯（電飾の雲。絵が読めるように紺を重ねてある） |
| `tab_home.png` `tab_log.png` `tab_camera.png` `tab_guide.png` `tab_spots.png` | タブの絵：テント・日記帳・にっこり三日月（撮影）・絵本・紙飛行機 |

作り方の注意

- 透過 PNG は `scripts/theme_chroma_key.py` でマゼンタを抜いたあと、**四辺に 5〜6% の透明な余白**を足してある。アプリは縁の 8 点の色で背景を判定するので、縁に絵がかかると黒抜きと誤判定されることがある
- うさぎは最初「円に抱きつく」絵で体が円の縁で切れて手が不自然だったので、全身の絵を別に作って差し替えた（2026-11-10 開発者の指摘）
- `theme.json` の `style`：`glass: true` + `glassBlur: false` + `glassOpacity: 1`（紺の面をそのまま）、`borderColor: "#FFE9D2D9"`（クリーム色の輪郭）、`chipOrnament: "☆"`、`captureFill: "#FFB3C6"`（ピンクの丸）、`glowColor: "#1E2A5E"`（円の後ろの紺の光）。書き方は `docs/07_theme_spec.md`
- 配置と色の予想図は `docs/ui/chiikawa_preview.jpg`
