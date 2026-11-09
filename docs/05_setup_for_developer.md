# 開発者（人間）の初期設定

Claude Code がループを回し始める前に、一度だけ必要な作業。順番通りに進める。
所要: 30〜60分（Apple 側の反映待ちを含む）。すべて iPad のブラウザでできる。

## 1. GitHub（5分）

1. リポジトリ `sawswork/fog` の Settings → Secrets and variables → Actions
2. **Variables** タブに追加
   - `BUNDLE_ID_PREFIX` = 逆ドメイン（例 `jp.example`）。バンドル ID は `{prefix}.fog` と `{prefix}.fog.widgets` になる
3. **Secrets** タブに追加（手順 2〜3 で取得した値）
   - `APPLE_TEAM_ID`
   - `ASC_KEY_ID`
   - `ASC_ISSUER_ID`
   - `ASC_PRIVATE_KEY`（.p8 の中身。生テキストでも base64 でも可。iPad なら Shortcuts で「ファイルを選択」→「Base64 エンコード」→「クリップボードにコピー」）
4. Settings → Actions → General → Workflow permissions を「Read and write」にする（Claude Code が PR を作るため）

Secrets が揃うまで `testflight` ワークフローは自動でスキップされる（`BUNDLE_ID_PREFIX` が空なら動かない）。`ios-build` と `core-tests` は Secrets なしで動く。

## 2. Apple Developer（15分 + 反映待ち）

developer.apple.com → Certificates, Identifiers & Profiles

1. **Team ID** を控える（Membership details）→ Secret `APPLE_TEAM_ID`
2. **Identifiers → App IDs** を2つ作る
   - `{prefix}.fog`（App）: Capabilities で **WeatherKit**, **iCloud**（CloudKit, コンテナ `iCloud.{prefix}.fog` を新規作成）, **App Groups**（`group.{prefix}.fog` を新規作成）, **Push Notifications** を有効化
   - `{prefix}.fog.widgets`（App）: **App Groups**（同じグループ）
3. **Services → WeatherKit** を有効化（App ID 側だけでなく、Services タブでも ON にする。反映に最大30分）
4. 証明書・プロファイルは作らなくてよい（CI が API キーで Apple Distribution 証明書を1枚作り、`scripts/ci/signing/` に暗号化して保存して使い回す。プロファイルは毎回作り直す）
5. `testflight` が「証明書の上限に達しています」で止まったら、Actions → `signing-admin` → Run workflow（`list`）で一覧を見て、不要な DISTRIBUTION 証明書の ID を `revoke` で失効させてから、失敗した `testflight` を Re-run する

## 3. App Store Connect（10分）

appstoreconnect.apple.com

1. **Users and Access → Integrations → App Store Connect API** で **Team キー**を作成。Access は **App Manager**
   - Key ID → Secret `ASC_KEY_ID`
   - Issuer ID → Secret `ASC_ISSUER_ID`
   - .p8 をダウンロード（1回しかできない）→ base64 → Secret `ASC_PRIVATE_KEY`
2. **Apps → ＋ → 新規 App**：プラットフォーム iOS、名前は仮で「Fog」、バンドル ID `{prefix}.fog`、SKU は任意
3. 自分を **TestFlight 内部テスター**に追加（App → TestFlight → 内部テスト → グループ作成 → 自分を追加）
4. iPhone に **TestFlight アプリ**を入れておく

## 4. 最初のループを始める

1. Claude Code で `sawswork/fog` を開き、「`docs/03_loop_plan.md` の L0 を始めて」と指示する
2. L0 の PR が来たら、CI が緑であることを確認してマージ
3. `testflight` ワークフローが走り、10〜20分後に TestFlight に通知が来る。インストールして5タブが出れば L0 完了
4. 以降は「次のループを始めて」の繰り返し。気づいたことは `feedback` ラベルの Issue にする

## 4.5 全ループ完了後の実機検証

L1〜L15 がマージされたら、`docs/06_device_verification.md` のチェックリストを iPhone 16 Pro で上から確認する。
丸一日の釣行（バッテリー・自動検出のしきい値）が含まれるので、数回の釣行に分けてよい。
問題は 1 件ずつ `feedback` ラベルの Issue にし、Claude Code に「feedback を処理して」と指示する。

## 5. 自分で決めること（いつでもよい）

- アプリの正式名（表示名）。決まったら `project.yml` の `CFBundleDisplayName` を変える
- 魚種判定の学習用に、過去の釣果写真を `App/Resources/Fixtures/` ではなく **別の場所**（iCloud Drive など）に集めておく。公開リポジトリには上げない。L6 でクラウド経由の取り込み方法を決める

## 6. リポジトリを非公開にするとき

完成後に Settings → General → Danger Zone → Change visibility。Secrets と Actions はそのまま使える。

非公開にすると GitHub Actions の実行時間が課金枠（Free プランは月 2,000 分、macOS は 10 倍換算）の対象になる。
そのため `ios-build` は PR と手動実行だけで動き（push では動かない）、同じブランチの連続実行は前のものを打ち切る。
`testflight`（macOS、1 回 4〜5 分）は main へのマージごとに動くので、まとめてマージする。使用量は Settings → Billing → Usage で見られる。
