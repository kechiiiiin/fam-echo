# fam-echo

家族が iPhone から打った文を、家じゅうの Echo に読み上げさせる仕組み。

```
iPhone アプリ（ios/）
   │  HTTPS  POST /speak {"from": "家族A", "text": "ご飯できたよ"}  + Bearer トークン
   ▼
(後日) Cloudflare Tunnel
   ▼
Mac の relay（relay/・127.0.0.1:8790・Python 標準ライブラリだけ）
   │  読み上げ文「家族Aから。ご飯できたよ」を組む
   │  POST /api/services/notify/alexa_media {"message", "target": [...], "data": {"type": "announce"}}
   ▼
Home Assistant（~/work/home-assistant・Docker・localhost:8123）
   ▼
Alexa Media Player ──▶ 全部屋の Echo
```

- 名乗り（「〇〇から。」）は **relay 側で組む**。アプリは名前と素の文を送るだけ
- HA 本体は外に出さない。外に出すのは relay だけで、合言葉（`FAM_ECHO_TOKEN`）を持つアプリだけを通す
- ボタン・履歴は各 iPhone の中だけ（SwiftData）。家族間で共有しない
- 家の外からは Cloudflare Tunnel（`fam-echo.kechiiiiin.com` → relay）で届く。常駐の手順は「外からつなぐ」の節

## relay（Mac 常駐の窓口）

| | |
|---|---|
| `POST /speak` | `Authorization: Bearer <FAM_ECHO_TOKEN>`。JSON `{"from", "text"}`。text は1〜500文字、from は1〜20文字（改行は空白に畳む） |
| `GET /health` | 認証なし。`{"ok": true, "status": "ok", "ha": {"reachable": true/false}}` |

| 返り値 | いつ |
|---|---|
| 200 `{"ok": true, "message": "家族Aから。ご飯できたよ", "targets": [...]}` | 読み上げを HA に頼めた |
| 400 `bad_request` | text / from が空・長すぎ・JSON でない |
| 401 `unauthorized` | トークンなし・違う（定数時間比較） |
| 502 `ha_unreachable` | HA が止まっている・届かない |
| 502 `ha_auth_failed` / `ha_token_missing` | HA のトークンが無効 / ファイルが読めない |
| 502 `no_targets` | 読み上げ先の Echo が見つからない |

### 設定（`relay/.env`・gitignore 済み）

`relay/.env.example` をコピーして埋める。主な項目:

- `FAM_ECHO_TOKEN` — アプリと共有する合言葉。`openssl rand -hex 32` で作る
- `HA_TOKEN_FILE` — HA の長期アクセストークンを入れたファイル（既定 `~/work/home-assistant/.ha-token`）。relay は**パスだけ**を持ち、中身はログにもレスポンスにも出さない
- `ECHO_TARGETS` — 読み上げ先の entity_id（カンマ区切り）。**空なら HA から自動で探す**:
  1. テンプレート API の `integration_entities('alexa_media')` で Alexa Media Player 由来の `media_player.*` を引く
  2. だめなら `/api/states` から、Alexa Media Player だけが持つ属性 `last_called` と `last_called_summary` がある `media_player.*` を拾う
  （どちらも空なら 502 `no_targets`。そのときは `ECHO_TARGETS` を書く）
- `ECHO_SPEAK_TYPE` — `announce`（お知らせ・全台一斉）か `tts`（1台ずつ読み上げ）。日本の Echo で announce が使えるかは**未確認**。だめなら `tts` に変える

### コマンド

```sh
make relay-test       # 単体テスト（HA は偽サーバー）
make relay-run        # 前面で起動（relay/.env を読む）
make relay-plist      # launchd の plist を relay/build/ に書き出すだけ
make relay-install    # ~/Library/LaunchAgents に置いて常駐（jp.kechiiiiin.fam-echo.relay）
make relay-uninstall  # 常駐をやめる
make relay-log        # ~/Library/Logs/fam-echo/relay.log を追う
```

本物の HA を起こさずに通しを試すときは `relay/dev_fake_ha.py`（偽 HA）を使う。

```sh
python3 relay/dev_fake_ha.py --port 18123 --token-file "$TMPDIR/fake-ha-token" &
HA_URL=http://127.0.0.1:18123 HA_TOKEN_FILE="$TMPDIR/fake-ha-token" python3 relay/fam_echo_relay.py
```

## 外からつなぐ（Cloudflare Tunnel）

名前付きトンネル `fam-echo`（id `72aee2c5-fe0c-44e1-8b8f-f87b9e049e5a`）で `https://fam-echo.kechiiiiin.com` を `http://127.0.0.1:8790`（relay）へ向ける。設定は `tunnel/config.yml.template`、常駐は `tunnel/launchd/` の plist。認証ファイル（`~/.cloudflared/*.json`・`cert.pem`）はリポジトリに入れない。

【持ち主・ブラウザ】（初回1回だけ）
1. `cloudflared tunnel login` — ブラウザが開くので kechiiiiin.com のゾーンを選んで許可（`~/.cloudflared/cert.pem` ができる）

【ヘスティア・コマンド】
1. `cloudflared tunnel create fam-echo`（認証ファイル `~/.cloudflared/<id>.json` ができる。id が変わったら `tunnel/config.yml.template` を直す）
2. `cloudflared tunnel route dns fam-echo fam-echo.kechiiiiin.com`
3. `make tunnel-plist` — config.yml と plist を `tunnel/build/` に生成し、`plutil -lint` と `ingress validate` で検証（何も読み込まない）
4. `make install` — relay と Tunnel の両方を launchd で常駐（Tunnel だけなら `make tunnel-install`）
5. `curl -s https://fam-echo.kechiiiiin.com/health` で確かめる。ログは `make tunnel-log`、やめるときは `make tunnel-uninstall`

## iOS アプリ（ios/）

- SwiftUI・iOS 17 以上・xcodegen（`ios/project.yml`）。bundle id `jp.kechiiiiin.famecho`、表示名 `fam-echo`
- 初回は「あなたは誰？」（家族の名前のボタン＋自由入力）。設定から変えられる。名前の候補はソースに書かず、ビルド時に `FAM_ECHO_FAMILY`（カンマ区切り）で入れる。空なら自由入力だけ
- メイン画面: 上に保存した文だけを出した横長ボタンの1列（タップで即送信・長押しで「編集」「削除」・削除は「元に戻す」付き）と最後の「＋ 追加」、下に大きな入力欄と横長の送信ボタン。右上に「履歴」と設定。送信中・届いた・送れなかった（理由つき）を表示
- 初期ボタンは「ご飯できたよ」「起きる時間だよ」。ボタン名は無く、読み上げる文がそのまま表示される。追加・編集・削除はメイン画面（長押し）で、並べ替えは設定 →「ボタンの並べ替え」
- 履歴（新しい順・日時つき）。行の右のアイコンか右スワイプで「ボタンに保存」、左スワイプで削除、右上の「すべて削除」
- 入力欄は Enter で送信しない（改行になるだけ・`onSubmit` なし）。日本語 IME の変換確定で誤送信しない
- 送信先・トークン・名前の候補は**ビルド時に埋め込む**: `ios/Secrets.xcconfig`（gitignore）→ `Config.xcconfig` が `#include?` → Info.plist → `AppConfig`。送信先が無ければアプリに「送信先 URL とトークンが未設定です」と出て送信ボタンが押せない

```sh
cp ios/Secrets.example.xcconfig ios/Secrets.xcconfig   # 埋める。URL の // は /$()/ と書く。名前の候補は FAM_ECHO_FAMILY = 名前A,名前B
make check     # xcodegen generate → シミュレータ向けビルド。警告・エラーが1つでもあれば失敗
make sim       # 専用シミュレータ FamEcho-Sim で起動
ios/scripts/uitest-local.sh [--shots]   # 偽 HA と relay を空いているポートで起動して UI テスト（--shots で ios/docs/ も撮り直す）
make uitest    # UI テストだけ（送信先は TEST_RUNNER_FAM_ECHO_URL / _TOKEN / _HA_DOWN_URL で渡す。無ければビルドに埋めた送信先）
ios/export-shots.sh [xxx.xcresult]   # UI テストのスクリーンショットを ios/docs/ に書き出す
```

UI テストは名前の候補を起動引数 `--uitest-family 家族A,家族B` で、送信先とトークンを `--uitest-url` / `--uitest-token` で差し込む（Debug ビルドで `--uitest-reset` のときだけ効く。`Secrets.xcconfig` は書き換えない）。`testFullFlow` は「名前選択 → ボタンで送信 → 入力欄で Return（送信されないこと）→ 送信ボタン → 履歴（新しい順）→ 履歴からボタンに保存 → 履歴を1件削除 → 初期ボタンの編集と削除 → 編集後のボタンで送信」を、`testMainScreenPresetActions` は「＋ 追加 → 長押しで編集 → 長押しで削除と元に戻す」を確かめる。`testErrorUnauthorized` / `testErrorHADown` / `testErrorUnreachable` は失敗表示、`testUnconfigured` は送信先と名前の候補が空のときの表示を確かめる。画面は `ios/docs/*.png`。

## 配る（TestFlight／実機へ直接）

- 家族は **TestFlight の外部テスター**（メールで招待）。最初のビルドだけ Beta App Review を通る
- 年齢制限などで TestFlight を使えない端末には、**開発用ビルドを Wi-Fi 越しに直接入れる**（`make device-install`）
- 配るビルドには `ios/Secrets.xcconfig` の送信先とトークンが埋め込まれる。`ios/build/`（.xcarchive・.ipa・ログ）はコミットも共有もしない（gitignore 済み）
- ビルド番号は `make archive` が日時で決める（`年月日.1時分`、例 `20261024.12101`）。`project.yml` は書き換えない。版（`MARKETING_VERSION` 0.1.0）は `project.yml` で上げる

### 【持ち主・ブラウザ】初回1回だけ（2か所）

1. **API キーを作って Mac に置く**: App Store Connect → ユーザとアクセス → 統合 → App Store Connect API → チームキー → 「＋」（API キーを生成）
   - 名前: `fam-echo` など／アクセス: **App Manager**
   - 初めてなら先に「アクセスをリクエスト」が要ることがある（推測）
   - 生成したら **.p8 をダウンロード（一度しかダウンロードできない）** して `~/.appstoreconnect/private_keys/AuthKey_<キーID>.p8` に置く
   - 同じ画面の **Issuer ID** と **キー ID** をヘスティアに伝える（`ios/Release.local.env` に書く）
   - App Manager のキーで配布用の署名（クラウド管理の配布証明書）が作れずに `make export-testflight` が止まったら、そのキーに「クラウド管理の配布証明書へのアクセス」を足すか、アクセスを Admin で作り直す（推測）
2. **アプリ枠を作る**（API では作れない）: App Store Connect → アプリ（マイ App） → 左上の「＋」 → 新規 App（推測: 画面名は時期で少し変わる）
   - プラットフォーム: iOS／名前: fam-echo（App Store 全体で重複不可。取られていたら「fam-echo 家族」など）／プライマリ言語: 日本語
   - バンドル ID: `jp.kechiiiiin.famecho`。2026-10-24 時点ではまだ開発者アカウントに登録されていない見込み（archive がワイルドカードのプロファイルで署名された）。一覧に無ければ、1. のあとヘスティアが `python3 ios/scripts/asc.py register-bundle-id` で登録してから選ぶ
   - SKU: `famecho`（自分用の識別子・何でもよい）／ユーザアクセス: フルアクセス
3. Beta App Review のテスト情報（連絡先の氏名・メール・電話、ベータ版の説明、フィードバックの宛先）をヘスティアに伝える。値は `ios/Release.local.env` にだけ書き、ソースには入れない

### 【ヘスティア・コマンド】初回

```sh
cp ios/Release.example.env ios/Release.local.env     # ASC_KEY_ID・ASC_ISSUER_ID・テスト情報を埋める
python3 ios/scripts/asc.py register-bundle-id        # バンドル ID を登録（アプリ枠を作る前・済みなら何もしない）
make release                                         # archive → App Store Connect へアップロード
python3 ios/scripts/asc.py builds                    # 処理が VALID になるまで待つ（数分〜数十分）
python3 ios/scripts/asc.py group                     # 外部テスターのグループ「家族」を作る
python3 ios/scripts/asc.py invite <メール> [名 姓]     # 招待する家族を1人ずつ
python3 ios/scripts/asc.py submit-review             # テスト情報を入れ、ビルドをグループに足して Beta App Review に出す
```

- 審査が通るとグループのテスターに招待メールが届く。各自 TestFlight アプリを入れて招待を受ける
- 審査メモ（`REVIEW_NOTES`）には「家の Mac 経由で Echo に読み上げさせる家族用アプリ。送信ボタンを押すと実際に家で読み上げられる」と書いておく（審査担当が試すと家の Echo が鳴る）
- どのコマンドも `--dry-run` を付けると、API を叩かずに送るはずのリクエストを表示する（例 `python3 ios/scripts/asc.py --dry-run submit-review`）。単体テストは `make -C ios asc-test`

### 【ヘスティア・コマンド】以後の更新

```sh
make release                          # 新しいビルド番号で上げる
python3 ios/scripts/asc.py builds     # VALID になったら
python3 ios/scripts/asc.py submit-review   # 2回目以降は審査が省かれることが多い（Apple 側の判断）
```

`make archive` → `make export-testflight` で、上げずに .ipa を `ios/build/export/` に書き出すだけもできる。

### TestFlight を使えない iPhone（開発用ビルドを Wi-Fi 越しに）

【家族・iPhone】初回1回だけ（Mac の前で）

1. ケーブルで Mac に繋ぎ、iPhone に出る「このコンピュータを信頼しますか？」で「信頼」→ パスコード
2. 設定 → プライバシーとセキュリティ → デベロッパモード → オン → 再起動 → 再起動後に「オンにする」→ パスコード（項目は Mac に一度繋ぐと出てくる）
3. スクリーンタイムで「App のインストール」を制限している端末では入らないかもしれない（推測）。止まったら一時的に許可する

【ヘスティア・コマンド】

```sh
make device-list                          # 名前・接続（wired / localNetwork）・デベロッパモードを見る
make device-install DEVICE="<名前かUDID>"   # 開発用署名でビルドして入れる。初回はその端末を開発者アカウントに登録する
make device-install DEVICE="<名前かUDID>" NAME="家族A"   # その iPhone の送り主の名前を焼き込む（日本語・空白可）
```

- `NAME=` を付けると、名前が `FAM_ECHO_FIXED_NAME` としてビルドに焼き込まれる。その iPhone では **名前選びを出さず、最初からその名前で送れる**。以前に別の名前を選んでいても焼き込みが優先され、設定画面は名前を表示するだけ（変更・自由入力の手段は出ない）。設定画面は家族向けに「名前・ボタンの並べ替え・Echo につながるか確かめる・バージョン」だけで、送信先やトークンは出さない。決まる順番は「焼き込み → 保存済み → 名前選び」
- `NAME=` を付けない（TestFlight・素のビルド）と、今までどおり名前選びが出て、設定から変えられる。前後の空白は除かれ、空や20文字超は焼き込み無しとして扱う（ビルドは通る）
- 名前は一台ごとに違うので `NAME=` は `device-install` だけで受ける。`archive`／`release`（TestFlight は全員同じビルド）には通さない。実際の名前は `Config.xcconfig` にも書かない

- 2回目以降はケーブル不要。Mac と同じ Wi-Fi にいて、画面ロックを解除しておく
- 署名は **Apple Development**（有料 Program の開発用プロファイル）。プロファイルは約1年で切れる。切れたら起動しなくなるので `make device-install` を打ち直す
- 端末の登録とプロファイル更新には、Xcode に Apple ID が入っているか、上の API キー（`ios/Release.local.env`）が要る

## 手作業の一覧

### 初回だけ

【ヘスティア・コマンド】
1. `openssl rand -hex 32` でトークンを作り、`relay/.env` と `ios/Secrets.xcconfig` に入れる（`chmod 600 relay/.env`）
2. `make relay-test` → `make relay-install` で常駐させ、`curl -s http://127.0.0.1:8790/health` で確かめる
3. Echo の entity_id が自動で見つからなければ HA の `/api/states` を引いて `ECHO_TARGETS` に書く
4. 「外からつなぐ」の手順で Tunnel を常駐させ、`ios/Secrets.xcconfig` の `FAM_ECHO_URL` を Tunnel の HTTPS にする
5. 「配る」の手順で TestFlight に上げ、家族を招待して Beta App Review に出す（`make release` → `asc.py`）。TestFlight を使えない iPhone は `make device-install`

【持ち主・ブラウザ】
1. HA の画面で Alexa Media Player に Amazon アカウントでログイン（2段階認証あり）
2. App Store Connect でアプリ枠を作り、API キー（.p8）を作って Mac に置く（「配る」の節。招待はヘスティアがコマンドで行う）
3. Tunnel 用に `cloudflared tunnel login`（ブラウザで許可・1回だけ）

【家族・iPhone】
1. TestFlight からアプリを入れて、名前を選ぶ（スクリーンタイムで制限している端末は許可が要るかもしれない）
2. TestFlight を使えない iPhone は、一度だけ Mac にケーブルで繋いでデベロッパモードをオンにする（「配る」の節）

### その後

- Alexa Media Player のログインが切れたら【持ち主・ブラウザ】で入り直す（頻度は未確認）
- アプリの更新・配布、relay の設定変更は【ヘスティア・コマンド】
- Mac がスリープ・停止していると届かない（常時起動の前提でよいかは未決）

## シークレットの置き場

| もの | 場所 | コミット |
|---|---|---|
| relay の合言葉 | `relay/.env` の `FAM_ECHO_TOKEN` | しない（gitignore） |
| アプリに埋める合言葉と URL・名前の候補 | `ios/Secrets.xcconfig` | しない（gitignore） |
| App Store Connect API キー | `~/.appstoreconnect/private_keys/AuthKey_<キーID>.p8` | しない（リポジトリの外） |
| キー ID・Issuer ID・審査のテスト情報 | `ios/Release.local.env` | しない（gitignore） |
| 配るビルド（.xcarchive・.ipa・ログ。合言葉と URL が埋め込まれる） | `ios/build/` | しない（gitignore） |
| HA の長期アクセストークン | `~/work/home-assistant/.ha-token`（relay はパスだけ持つ） | このリポジトリには無い |
