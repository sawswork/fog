# forest — 「ホーム 1 画面」の配置の例（F-58）

`theme.json` だけで成立するテーマの例。画像は未同梱（置けば使われる）。

- `bg_home.jpg`：全画面の背景（縦 9:16）
- `char_home.png`：中央のキャラクター（マゼンタ背景か透過 PNG。`rect` の中に `fit` で収まる）
- `map_frame.png`：地図の上に重ねる飾り（任意）
- `tab_home.png` … `tab_spots.png`：`nav` 部品のアイコン（無ければ SF Symbols）

座標は画面の幅・高さに対する割合 `[x, y, w, h]`。詳しくは `docs/07_theme_spec.md`。
