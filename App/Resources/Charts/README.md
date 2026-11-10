# Charts — 港の海図（F-63）

海図の 1 画面で、釣行中に出す港の図。ファイル名は `<id>.jpg`（縦 3:4、北が上）。どこを写しているかは `Packages/Core/Sources/Core/Data/port_charts.json`（中心の緯度経度・地上の幅と高さ・水面の網目）に入っている。

- 作り方：`scripts/port_charts/batch.py` が、国土地理院の地理院タイル（航空写真 `seamlessphoto` と淡色地図 `pale`）を港ごとに切り出し、Gemini `gemini-3.1-flash-image`（1K）に「同じ位置・同じ形のまま海図風に描き直す」よう頼む。描いた絵の水面と地図の水面の重なり（IoU）が 0.68 未満なら作り直し、3 回だめなら入れない
- 見本は「港の形を含まない質感の見本」（`scripts/port_charts/style_swatch.jpg`）。港の絵を見本にすると、その形に引きずられる
- まとめ：`python3 scripts/port_charts/build_index.py <out フォルダ>`
- 出典：国土地理院の地理院タイルを加工して作成（アプリの 設定 > 情報源 に表示）
- 浅く見える所の明るい色は航空写真の見た目から描いたもので、測った水深ではない
- ここに無い港は、アプリが Apple の地図を暗くして代わりに出す
