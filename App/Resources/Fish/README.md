# Fish — 図鑑の魚の画像（F-60）

`scripts/fetch_fish_db.py` が Wikimedia Commons から取ってきた種の画像（長辺 900 px・JPEG）。ファイル名は `scripts/fish_species_list.json` の `id`。
ライセンスは CC BY / CC BY-SA / CC0 / パブリックドメインのものだけ。作者・ライセンス・元ファイルは `Packages/Core/Sources/Core/Data/fish.json` の `imageCredit` にあり、アプリの詳細画面に表示する。
手で画像を差し替えるときも、同じ条件のライセンスのものにして `imageCredit` を直すこと。
