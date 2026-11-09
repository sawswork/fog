# 魚種判定の対象リスト（初期）

北海道・道南の漁港ロックフィッシュを優先。学習データは `scripts/train_classifier/`（公開データ＋開発者の写真）。Core の `Species.initialCatalog` と同じ内容にする。

| 標準和名 | 地方名・別名 | 優先 | 学名（iNaturalist 検索用） |
| --- | --- | --- | --- |
| アイナメ | アブラコ | 高 | Hexagrammos otakii |
| クロソイ | ソイ | 高 | Sebastes schlegelii |
| マゾイ（キツネメバル） | マゾイ | 高 | Sebastes vulpes |
| シマゾイ | | 高 | Sebastes trivittatus |
| エゾメバル | ガヤ | 高 | Sebastes taczanowskii |
| ムラソイ | ハチガラ | 高 | Sebastes pachycephalus |
| カジカ（トゲカジカ・ギスカジカ） | ナベコワシ | 中 | Myoxocephalus polyacanthocephalus |
| ホッケ | | 中 | Pleurogrammus azonus |
| クジメ | | 中 | Hexagrammos agrammus |
| マコガレイ・クロガシラガレイ | カレイ | 中 | Pseudopleuronectes yokohamae / P. schrenki |
| ウグイ | | 低（外道） | Pseudaspius hakonensis |
| ヒラメ | | 低 | Paralichthys olivaceus |
| ブリ（イナダ・フクラギ） | | 低 | Seriola quinqueradiata |
| サクラマス | | 低 | Oncorhynchus masou |
| ヤリイカ | ヤリ、テナシ | 中（2026-11-09 追加） | Heterololigo bleekeri |
| スルメイカ | マイカ、イカ | 中（2026-11-09 追加） | Todarodes pacificus |
| ヒイカ | ジンドウイカ、コイカ | 低（2026-11-09 追加） | Loliolus japonica |

イカ類は全長ではなく胴長で測るのが通例なので、図鑑の見出しに「胴長」と添える（LiDAR の計測はそのまま）。
