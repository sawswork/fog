# Fish — 図鑑の魚の画像（F-60）

`scripts/fetch_fish_db.py`（Wikimedia Commons）と `scripts/fetch_inat_images.py`（iNaturalist）が取ってきた種の画像（JPEG。手選びの種は長辺 640 px、他は 480 px）。2026-11-10 時点で 4,294 種中 2,959 種分。残りは使えるライセンスの写真が見つからなかった種。ファイル名は `scripts/fish_species_list.json` の `id`。
ライセンスは CC BY / CC BY-SA / CC0 / パブリックドメインのものだけ。作者・ライセンス・元ファイルは `Packages/Core/Sources/Core/Data/fish.json` の `imageCredit` にあり、アプリの詳細画面に表示する。
手で画像を差し替えるときも、同じ条件のライセンスのものにして `imageCredit` を直すこと。
