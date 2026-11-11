# テーマ定義 `theme.json`（F-58）

テーマは `App/Resources/Themes/<folder>/` に **画像と `theme.json`** を置くだけで増やせる。コードは触らない。
`theme.json` は (1) 配色・書体の上書き、(2) ホーム 1 画面の「部品の配置」を持つ。起動時に全フォルダを探し、設定 > テーマ に並ぶ。

## 1. 全体

```json
{
  "version": 1,
  "label": "森",
  "base": "grimoireDark",
  "fallbackFolder": "grimoire",
  "light": false,
  "fonts": { "text": "serif", "number": "serif" },
  "colors": { "accent": "#9BE3B3", "panel": "#0B1A1466" },
  "home": { ... }
}
```

| キー | 意味 |
| --- | --- |
| `label` | 設定に出る名前 |
| `base` | 土台（`dark` / `grimoire` / `grimoireDark` / `tensura`）。配色・書体・明暗の既定をここから取る。省略は `dark` |
| `fallbackFolder` | このフォルダに無い画像を借りるフォルダ |
| `light` | 明るい地か（シートやコントロールの配色も合わせる） |
| `fonts.text` / `fonts.number` | `default` / `serif` / `rounded` / `monospaced` |
| `colors` | 上書きする色。キー：`background` `surface` `surfaceRaised` `accent` `secondary` `sun` `daylight` `textPrimary` `textSecondary` `textTertiary` `faded` `sea` `moon` `saturday` `holiday` `panel` `scrim`。値は `#RRGGBB` か `#RRGGBBAA` |
| `home` | ホームの配置（無ければ従来の縦積み＋タブバー） |
| `style` | **標準レイアウトの部品の見た目**（2026-11-09 追加）：`chipTilt`（チップの面内の傾き、度）、`chipPerspective`（縦軸まわりの回転、度。奥行き）、`glass`（チップと予報カードをすりガラス＋薄い白い枠に）、`glassOpacity`（その上の面の濃さ 0〜1、省略 0.35。小さいほど背景が透ける）、`glassBlur`（すりガラスのぼかしを使うか。false なら薄い色の面だけで背景がそのまま透ける。省略 true）、`chipOrnament`（チップの角の飾り文字、例 "✦"）、`captureSymbol`（撮影ボタンの SF Symbols 名、例 "moon.fill"）。`App/Resources/Themes/fern/` が例。**2026-11-10 追加**：`borderColor`（面の輪郭線の色 `#RRGGBB` / `#RRGGBBAA`。チップ・予報カードと、ログ・図鑑・地図などのカードに共通で付く。省略は輪郭なし）、`borderWidth`（輪郭線の太さ pt、省略 1.5、0.5〜4）、`captureFill`（`tab_camera` があるテーマの撮影ボタンの丸の色）、`glowColor`（釣れ率の円の後ろの光の色。暗い色にすると明るい背景でも数字が読める）。`App/Resources/Themes/chiikawa/` が例 |
| `screen` | **画面の構成**（2026-11-11 追加）：省略か `tabs` はこれまでの 5 画面とタブ。`chart` は海図の 1 画面（F-63。開始・撮影・終了と港の図）。`App/Resources/Themes/chart/` が例。このとき `home` と `style` は使われず、`colors` は「≡」から開くログ・図鑑・設定などの配色になる |

組み込みのフォルダ（`grimoire` など）に `theme.json` を置くと、その組み込みテーマの上書きになる。

設定 > テーマ のカードの絵は、フォルダに `thumb.jpg`（か png）があればそれ、無ければ `bg_home` を縮めたもの。

## 2. ホームの配置 `home`

```json
"home": {
  "hidesTabBar": true,
  "scrim": 0.2,
  "layers": [
    { "image": "bg_home", "rect": [0, 0, 1, 1], "fit": "fill", "z": 0 },
    { "image": "char_home", "rect": [0.08, 0.16, 0.84, 0.62], "fit": "fit", "z": 40, "opacity": 1 }
  ],
  "blocks": [
    { "type": "header", "rect": [0.04, 0, 0.92, 0.13], "z": 60 },
    { "type": "score", "rect": [0.28, 0.11, 0.44, 0.20], "z": 50 },
    { "type": "nav", "rect": [0, 0.92, 1, 0.08], "z": 100, "style": "compact" }
  ]
}
```

- 座標 `rect` は **画面の幅・高さに対する割合** `[x, y, w, h]`（左上が 0,0。安全領域を含む全画面が基準。`{"x":..,"y":..,"w":..,"h":..}` でもよい）
- `z` が小さいものから下に重ねる。画像（layers）と部品（blocks）は同じ z の空間に置かれる（キャラクターを部品の前にも後ろにも置ける）
- `hidesTabBar: true` でタブバーを消す。画面の行き来は `nav` か `button` の部品で。ホーム以外の画面には右下に「ホームへ戻る」ボタンが出る
- `scrim` は画像の上に敷く黒い幕の濃さ（0〜1）。省略は土台の既定

### 画像の層 `layers[]`

| キー | 意味 |
| --- | --- |
| `image` | フォルダ内のファイル名（拡張子なし。png / jpg） |
| `rect` | 置く長方形。省略は全画面 |
| `fit` | `fill`（はみ出しを切って埋める）/ `fit`（全体が入る） |
| `opacity` | 0〜1 |
| `blend` | `auto`（マゼンタ背景は透明に抜く、黒背景は黒を透かす）/ `normal` |
| `motion` | 画像の動き：`float`（上下にふわり＋かすかな呼吸。キャラクター向け）/ `breathe`（呼吸）/ `sway`（左右に揺れる）/ `spin`（1 周 60 秒で回る。魔法陣向け）/ `drift`（背景がゆっくり寄って戻る）/ `pulse`（明滅）。省略は動かない |
| `speed` / `amount` | 動き・効果の速さと大きさの倍率（既定 1。速さ 0.1〜5、大きさ 0〜3） |
| `effect` | **画像の代わりに描く効果**（`image` は要らない）：`fireflies`（光の粒）/ `leaves`（舞う葉）/ `sparkles`（きらめき）/ `bubbles`（泡）。`count`（粒の数、効果ごとの既定あり、最大 200）と `color`（`#RRGGBB`、省略はアクセント色）で調整 |

```json
{ "image": "char_home", "rect": [0.12, 0.19, 0.76, 0.58], "fit": "fit", "z": 40, "motion": "float" },
{ "effect": "fireflies", "z": 10, "count": 34, "color": "#9BE3B3" }
```

動きは Core Animation の繰り返しアニメーションだけで動かし（毎フレームの再描画なし）、効果は 30 fps の Canvas で描く（粒の位置は番号から決まるので状態を持たない）。
画面が前面でないときと、iOS の「視差効果を減らす」が有効なときは止まる。

### 部品 `blocks[]`

| `type` | 中身 | 既定のタップ |
| --- | --- | --- |
| `header` | 釣り場名・時刻・開始/終了・相談・月・歯車（上の安全領域を自動で避ける） | 各ボタン |
| `score` | 釣れ率の円（記録中はライブ画面） | 内訳 |
| `chips` | 今の 4 チップ | 各チップの詳細 |
| `feedLine` | 釣果情報の 1 行 | 一覧 |
| `forecast` | 日付・グラフ・表・週・水温の全部（タブ版と同じ） | — |
| `chart` | 日付とグラフだけ | グラフをタップで時刻の詳細 |
| `table` | 3 時間ごとの表だけ | — |
| `week` | 週の見通しだけ | 日へ |
| `recentCatches` | 直近の釣果の写真（幅に収まるだけ） | `log` |
| `miniMap` | 周りの釣り場の小さな地図（釣れ率の円） | `spots` |
| `nav` | 5 つの画面のアイコン（`tab_*.png` があればそれ。`style: "compact"` で小さく） | 各画面 |
| `button` | 1 つのボタン。`image`（フォルダの画像）か `symbol`（SF Symbols） | `action` |
| `text` | `text` の文字。`style`: `caption` / `label` / `title` | — |
| `date` | 表示中の日付 | 年間カレンダー |

共通のキー：`rect` `z` `opacity` `action` `background`（`none` / `panel` / `glass`）`padding`（pt）。

`action` の値：`home` `log` `capture` `guide` `spots` `settings` `breakdown`（内訳）`feed`（釣果情報）`assistant`（相談）`spotSwitch`（釣り場切替）`moon` `year` `toggleSession`（開始/終了）`none`。

## 3. 作り方のコツ

1. Gemini などで背景（9:16）とキャラクター（マゼンタ背景）を作り、フォルダに置く
2. `theme.json` を書く。まず `layers` だけで見た目を決め、次に `blocks` を置く。座標は iPhone 16 Pro（402×874 pt）の割合で考える
3. 置いた部品が画像の泡や枠に乗るように `rect` を合わせる。部品の後ろに面が要らなければ `background` は省略（`none`）
4. `docs/06_device_verification.md` の手順で TestFlight に配信して確認する

知らない `type` は無視される（古いビルドでも落ちない）。`rect` の範囲外は 0〜1 に収められる。読めない `theme.json` のフォルダはテーマとして出ない。
`App/Resources/Themes/forest/` が最小の例。

## 4. 海図の 1 画面の着せ替え `chart`（2026-11-11、F-63）

`"screen": "chart"` のテーマは、`chart` で海図の画面の色・書体・配置を変えられる（省略は標準の海図：濃紺にオレンジ）。`App/Resources/Themes/sylphie_lake/` が例。

```json
"screen": "chart",
"chart": {
  "colors": { "background": "#0A1310", "text": "#F7F0E1", "sub": "#C9D0C0", "dim": "#8C9A8A",
              "accent": "#F4B860", "tide": "#9FD0F0", "panel": "#12221B", "border": "#D8D2BC8C", "onAccent": "#1F1407" },
  "font": "serif", "numberFont": "serif",
  "idleNumberSize": 86, "idleFaceGap": 0.2, "idleTopScrim": 0.42, "idleBottomScrim": 0.9,
  "idleEffects": ["fireflies", "sparkles"],
  "mapFrame": true, "menu": "panel", "glow": 0.5
}
```

| キー | 意味 |
| --- | --- |
| `colors` | `background`（地）`text` `sub` `dim`（文字の 3 段）`accent`（押すところ・釣れる時間・投げる場所）`tide`（潮）`panel`（札やボタンの面）`border`（輪郭線。書くとボタンが二重の縁になる）`onAccent`（強調色の面に載せる文字） |
| `font` / `numberFont` | `default` / `serif` / `rounded` / `monospaced`。`serif` でも 12 pt より小さい字は標準の書体のまま（読みやすさ） |
| `idleNumberSize` | 待機中の釣れ率の数字（pt、60〜140、省略 124） |
| `idleFaceGap` | 待機中、数字の下に空ける高さ（画面の高さに対する割合、0〜0.4）。背景のキャラクターの顔を見せる。書くと、数字は上へ寄り、次の山と数字の行は半透明の札に載る |
| `idleTopScrim` / `idleBottomScrim` | 背景の上・下に敷く幕の濃さ（0〜1） |
| `idleEffects` | 背景に重ねる効果：`fireflies` `sparkles` `leaves` `bubbles`（色は `accent`） |
| `mapFrame` | 釣行中の地図を額（外の線＋四隅の `chart_corner`）で囲む |
| `menu` | `panel` で、右上のメニューがテーマの色と印（`chart_menu_*`）の札になる。省略は iOS の一覧 |
| `glow` | 開始・撮影ボタンのまわりの光の強さ（0〜1、省略 1） |

画像（テーマのフォルダ。無いものは標準の海図の素材）：

| ファイル | 内容 |
| --- | --- |
| `chart_bg_idle` | 待機中の背景（縦長。画面いっぱいに敷く） |
| `chart_orb_start` / `chart_orb_shutter` | 開始ボタン（中央は空ける。「開始」はアプリが書く）／撮影ボタン。正方形・透過 |
| `chart_dial` | 風向の計器の枠（針はアプリが描く。上が北） |
| `chart_corner` | 枠の角飾り。**左上向き**の絵を 1 枚（アプリが鏡映しで四隅に置く）。透過 |
| `chart_menu_log` `_guide` `_spots` `_feed` `_assistant` `_settings` | メニューの印。正方形・透過 |

「≡」から開くログ・図鑑・設定などは、これまでどおり `colors` と `bg_log` `bg_guide` `bg_sheet` などを使う。

