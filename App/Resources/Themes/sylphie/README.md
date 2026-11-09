# sylphie — 森の魔法陣（開発者の参考イメージの配置例、F-58）

タブバーの無い 1 枚のホーム。画像は Gemini で作って置く（無い間は色と書体だけで動く）。

| ファイル | 内容 | 置き方 |
| --- | --- | --- |
| `bg_home.jpg` | 夜の森と光の粒子（縦 9:16） | 全画面に `fill` |
| `ring_home.png` | 釣れ率の後ろの魔法陣（正方形・マゼンタ背景か透過） | 上部中央（幅 60%）に `fit` |
| `char_home.png` | シルフィ（縦長・マゼンタ背景か透過） | 中央（幅 80%・高さ 60%）に `fit` |
| `map_frame.png` | 下の地図に重ねる飾り（横長、任意） | 下部に `fill` |
| `tab_home.png` … `tab_spots.png` | 最下段の 5 つの印（正方形・マゼンタ背景） | `nav` 部品が使う |
| `bg_log.jpg` `bg_guide.jpg` `bg_sheet.jpg` `bg_detail.jpg` `tabbar.jpg` | 他の画面の背景（任意） | 従来どおり |

配置（`theme.json` の `home.blocks`）は参考画像から割合で起こしてある。泡の位置に合わせて `rect` を調整する。書き方は `docs/07_theme_spec.md`。
