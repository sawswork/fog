# CLAUDE.md — 釣りアプリ（コードネーム: Fog）

このリポジトリは **iPhone 16 Pro 専用・本人利用のみ・完全ローカル** の釣りアプリを、
**ループエンジニアリング**で最後まで一貫して実装するためのものです。
開発者は Mac を持たず iPad から GitHub 経由で作業します。**ビルドは GitHub Actions の macOS ランナーだけ**で行います。

## 最初に読むもの（この順で）

1. `docs/01_requirements.md` — 機能要件定義 v0.1（F-01〜F-27、優先度付き）
2. `docs/02_ui_design.md` — UI設計 v1.0（5画面＋ウィジェット、`docs/ui/*.jpg` が確定イメージ）
3. `docs/03_loop_plan.md` — ループ計画。**今どのループか・次に何をするかはここが正**
4. `docs/04_decisions.md` — 決定事項ログ。迷ったらここに書いてから進む
5. `docs/research/data_sources.md` — 潮汐・海況・釣果情報の取得元の調査結果
6. `docs/06_device_verification.md` — 実機検証チェックリスト（L16、開発者が iPhone で確認する項目）
7. `docs/07_theme_spec.md` — テーマ定義 `theme.json`（配色・書体・ホームの部品の配置。テーマはコードを触らずフォルダで増やす）

## 絶対に守る3原則

1. **撮影以外は全自動** — ユーザー入力は魚の撮影だけ。例外的入力（タックル切替、低確信度時の候補選択、針ロスト）は未入力でも記録が成立すること。
2. **釣果は自動分析** — 記録と同時に分析結果が更新される。ユーザーが集計操作をすることはない。
3. **完全ローカル** — 自前サーバーなし。外部通信は WeatherKit / Open-Meteo Marine / 気象庁潮位表 / 登録RSS の取得のみ。写真・釣果・位置は端末と本人の iCloud 以外に出さない。

## 技術スタック（変更する場合は docs/04_decisions.md に理由を書く）

- Swift 5 言語モード / SwiftUI / SwiftData / iOS 26.0+（Foundation Models を使うため）
- 対象端末: iPhone 16 Pro のみ（LiDAR・Apple Intelligence 前提で設計してよい）
- Xcode プロジェクトは **XcodeGen** (`project.yml`) で生成する。`.xcodeproj` はコミットしない
- 純粋ロジック（潮汐・釣れ率・統計・天文計算・モデル）は `Packages/Core` に置き、**Linux の `swift test` で検証できる**ようにする（Foundation 以外に依存しない）
- iOS 依存（SwiftUI, CoreLocation, WeatherKit, ARKit/LiDAR, CoreML, WidgetKit, CloudKit）は `App/` に置く
- デザイン: ダーク固定、背景 #0B0B0C、アクセント #739E78（緑。2026-11-04 にオレンジから変更）、潮は青 #4D9EF2、マズメは黄 #F5C542、日の出入はオレンジ #FF7A1A、月は紫、現在線は白、週行の土曜は青 #5CA3FF・日曜と祝日は赤 #FF5C5C（日付の文字だけ）。枠線なし、文字最小、SF Pro / 数字は SF Pro Rounded。`App/Sources/DesignSystem/` のトークンを必ず使う
- 全画面は縦スクロールなしの1画面に収める（例外: 図鑑グリッドのみ縦スクロール可）

## ループの回し方（必ずこの手順）

1. `docs/03_loop_plan.md` の状態表で **status が `next` のループ**を1つ選ぶ。先行ループが `done` か `review`（CI 緑・開発者の実機確認待ち）でなければ着手しない。`blocked` の備考に自分で解消できることが書いてあれば先にそれをやる。
2. ブランチ `loop/L{番号}-{slug}` を main から切る。
3. そのループの「受け入れ条件」をすべて満たすまで実装する。
   - `Packages/Core` の変更は `cd Packages/Core && swift test` をローカル（Linux）で通す。
   - iOS 側の変更は PR を作ると CI (`.github/workflows/ios-build.yml`) が回る（push だけでは回らない。手動は Actions の Run workflow）。ローカルではビルドできない。リポジトリは非公開で macOS ランナーは 10 倍換算なので、細かい push を重ねず PR 単位で回す。
   - CI の結果は `gh run list --branch <branch>` → `gh run view <id> --log-failed` で読む。赤なら直して push。**緑になるまでループを終えない**。
4. 緑になったら PR を作る。本文にそのループの受け入れ条件をチェックリストで貼り、満たしたものにチェックする。
5. `docs/03_loop_plan.md` の状態表を更新（`in_progress` → `review`）。設計判断があれば `docs/04_decisions.md` に追記。
6. 開発者が iPhone（TestFlight）で確認し、PR をマージするか、`feedback` ラベルの Issue を立てる。
7. 次のループの最初に、`feedback` ラベルの未対応 Issue を先に処理してから進む。

### ループ中の約束

- 1ループ = 1PR。他のループの範囲に手を出さない（気づいたことは Issue にする）。
- 要件・UI設計に書いていないことを勝手に足さない。足したいときは `docs/04_decisions.md` に「提案」として書き、PR 本文で問う。
- 外部 API のキー・証明書・秘密情報は絶対にコミットしない。CI の Secrets を使う。
- テストデータ・ダミー画像はコミットしてよい（`App/Resources/Fixtures/`）。
- コミットメッセージは `L{番号}: {何をしたか}`。

## よく使うコマンド

```bash
# Core パッケージのテスト（Linux で動く）
cd Packages/Core && swift build && swift test

# CI の状態
gh run list --limit 5
gh run view <run-id> --log-failed

# 気象庁の分潮データを取り込む（L3）
python3 scripts/fetch_jma_harmonics.py --out data/tide/harmonics.json
```

## 開発者（人間）が担当すること

CI の Secrets 登録、App Store Connect の設定、TestFlight での実機確認、PR のマージ。
これらが未完了で止まる場合は、PR 本文に「開発者の作業待ち: ○○」と明記して止まる。
