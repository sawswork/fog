# fern — 月夜の桜（F-58、2026-11-09）

開発者のモック（紫の配色・ガラスの傾いたチップ・明朝の数字・月の撮影ボタン）を **標準レイアウト**のまま再現するテーマ。`home` の配置は持たず、`colors` と `style` だけで見た目を変える。

| ファイル | 内容 | 作り方 |
| --- | --- | --- |
| `bg_home.jpg` | 開発者が添付したキャラクターの絵を Gemini（ネイティブ API、参考画像つき、2K）に渡し、黒地だけを月明かりの紫の夜空と散る桜に差し替えたもの | 彼女はそのまま |
| `bg_spots.jpg` | 同じ夜空でキャラクター無し | Gemini |
| `bg_log.jpg` `bg_guide.jpg` `bg_sheet.jpg` `bg_detail.jpg` | 他の画面の暗い紫の背景 | Gemini |
| `ring_home.png` | 釣れ率の周りの細い魔法陣（透過） | Gemini → `scripts/theme_chroma_key.py` |

`style`：`chipTilt: -4`（面内の傾き）、`chipPerspective: 16`（縦軸まわり、奥行き）、`glass: true`（チップと予報カードをすりガラス＋白い枠に）、`glassOpacity: 0.14` と `glassBlur: false`（ぼかしを使わず薄い面だけにして背景をそのまま見せる。2026-11-09 開発者「枠を薄くして背景を見えるように」「薄さが変わっていない」→ iOS の material 自体が暗かったのでぼかしを外した）、`chipOrnament: "✦"`、`captureSymbol: "moon.fill"`。書き方は `docs/07_theme_spec.md`。
