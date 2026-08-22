# Mac App Store での配布

買い切り（有料アプリ）として App Store に出すための手順。

---

## 0. サンドボックスでの動作（確認済み）

**App Store のアプリは App Sandbox が必須です。** このアプリの中核がサンドボックス内で
動くかどうかが最大の前提でしたが、**2026-08-06 に実機で確認し、通りました。**

| | |
|---|---|
| Process Tap の生成 | ✅ 通る |
| プライベート集約デバイスの生成 | ✅ 通る |
| アプリごとの音量調整 | ✅ 効く |
| 確認方法 | `make run-sandboxed` で起動し、コンテナ生成・署名・ログ・実挙動を確認 |

サンドボックス用のエンタイトルメントは `com.apple.security.app-sandbox` の 1 つだけで、
「システム音声録音」の許可は従来どおり TCC で与えられます。

以下は、コードを変えたあとに**この前提が崩れていないかを確かめ直す**ための手順です。
提出前に一度は通してください。

### 準備

署名 ID を固定します。ad-hoc 署名だとビルドのたびに ID が変わり、そのたびに
「システム音声録音」を許可し直すことになって、何が原因で動かないのか分からなくなります。

```bash
security find-identity -v -p codesigning
```

Apple Development の証明書があればそれを使います。同じ名前が複数並ぶときは
（失効した古いものが残っている場合など）名前ではなく**ハッシュで指定**します。
名前が重複していると `codesign` が判別できずに止まります。

```bash
make run IDENTITY=<40桁のハッシュ>
```

証明書が 1 枚も無ければ、キーチェーンアクセス → 証明書アシスタント → 証明書を作成
（名前 `AppMixer Dev`、証明書のタイプ **コード署名**、自己署名ルート）で作れます。

### 1. まず基準を取る（サンドボックス無し）

いきなりサンドボックスで試して失敗すると、サンドボックスのせいなのか、そもそも
環境の問題なのかが区別できません。先に普通のビルドで動くことを確かめます。

```bash
make run IDENTITY="AppMixer Dev"
```

音楽を再生し、一覧に出たアプリのスライダーを動かして**音量が変わること**を確認します。
（初回は「システム音声録音」の許可を求められます。許可後は一度終了して再実行。）

ここが動かないなら、サンドボックス以前の問題です。

### 2. サンドボックスを付けて同じことを試す

前のプロセスを必ず終了させます。残っていると `open` が既存のプロセスを前に出すだけで、
**古いビルドを見ながら「動いた」と判断してしまいます。**

```bash
osascript -e 'quit app "AppMixer"' 2>/dev/null; killall AppMixer 2>/dev/null; sleep 1
make run-sandboxed IDENTITY="AppMixer Dev"
```

`App Sandbox: 有効` と出ることを確認してから、**1 とまったく同じ操作**をします。

### 3. ログを見る

操作したあとに実行します。

```bash
log show --last 3m --predicate 'subsystem == "io.github.iam74k4.AppMixer"' --style compact
```

サンドボックス下で起動したかは、コンテナの有無が確実です。

```bash
ls -ld ~/Library/Containers/io.github.iam74k4.AppMixer
```

サンドボックス版は `UserDefaults` もコンテナの中を読むため、**保存した音量が空に見え、
「システム音声録音」の許可も改めて聞かれます。**異常ではありません。許可を出さないまま
だとタップが作られず、「サンドボックスで動かない」と誤判定します。

| 見えるもの | 意味 |
|---|---|
| 音量が変わり、ログにエラーが出ない | **通った** |
| `AudioHardwareCreateProcessTap failed` | タップを作れていない（`ProcessTap.swift:44`） |
| `AudioHardwareCreateAggregateDevice failed` | 集約デバイスを作れていない（同 `:48`） |
| 行に「設定を適用できませんでした」の印が出る | 上のいずれかが起きている |

出力デバイスの切り替え（ヘッダーのデバイス名）も試してください。こちらは
`CoreAudioObject.swift:153` の書き込みが通るかを見ています。

実際にサンドボックスが効いているかは、こちらでも確かめられます。

```bash
codesign --display --entitlements - dist/AppMixer.app
```

**ここで落ちるようになったら、App Store には出せません。** 音量調整ができないアプリに
なるため、機能を削って出す形にもなりません。その場合は直販（Developer ID 署名 + 公証）
へ戻ることになります。直販の手順（`docs/release.md`）と、買い切りライセンス認証の
実装一式（Ed25519 の検証・キーチェーン・試用期間・発行ツール）は
`claude/perpetual-license-auth-uua0ew` ブランチに残してあります。

### 4. 元に戻す

確認が済んだら、`make run` で通常の署名に戻しておいてください。

---

## 1. 通った場合にやること

### アプリ側のライセンス機構（撤去済み）

App Store では購入の判定を OS が行うため、独自のライセンス機構は要りません。
以下はすでに取り除いてあります。

- `Sources/AppMixer/License/` 一式（Ed25519 の検証、キーチェーン、試用期間）
- `MixerModel` のゲーティング
- ライセンスキーの発行ツールと、購入時に動かしていた Worker

**試用期間もありません。** App Store に体験版の仕組みは無く、実現するには
「無料アプリ + App 内課金で機能解除」に作り替える必要があります（買い切りの
有料アプリとは別の設計です）。買う前に試せない点は、説明文とスクリーンショットで
補うことになります。

### Apple 側で用意するもの

| | どこで |
|---|---|
| App ID | Certificates, Identifiers & Profiles。`io.github.iam74k4.AppMixer` |
| **Apple Distribution** 証明書 | アプリの署名用 |
| **3rd Party Mac Developer Installer** 証明書 | pkg の署名用 |
| プロビジョニングプロファイル（Mac App Store 用） | App ID に紐づけて作成し、ダウンロード |
| App Store Connect のアプリレコード | 価格（買い切り）、説明文、スクリーンショット |

### バージョンを上げる

`bundle/Info.plist` の `CFBundleShortVersionString` を更新します（例 `0.1.0`）。
Makefile はここからバージョンを読み、`CFBundleVersion`（ビルド番号）はそこから
機械的に導いて `.app` へ書き込みます。手で増やす必要はありません。

App Store はビルド番号が**前回より大きい**ことを求めます。同じバージョンで
出し直すときは `BUILD_NUMBER=<数値>` を渡して上書きしてください。

`CHANGELOG.md` の「未リリース」を新しいバージョン見出しに移し、日付を入れます。
ここまでを `develop` へコミットしておきます。

### 提出物を作る

`develop` を `main` へマージすると、CI が以下と同じものを作って App Store Connect へ
アップロードし、そのまま審査に出します（`docs/release-flow.md`）。手元で作る場合:

```bash
make clean
make mas \
  MAS_IDENTITY="Apple Distribution: <名前> (<TEAMID>)" \
  MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: <名前> (<TEAMID>)" \
  PROVISION_PROFILE=AppMixer.provisionprofile
```

`dist/AppMixer-<version>.pkg` ができます。**Transporter.app** で App Store Connect へ
アップロードします。

公証（notarization）は要りません。Hardened Runtime も使わず、代わりに
App Sandbox が付きます。

### 審査に出すときに書くこと

このアプリは他のアプリの音声を取得します。**何のために必要で、何をしていないのかを
審査メモに明記してください。** 書かないと、まず質問が返ってきます。

- アプリごとの音量を変えるために音声を経由させていること
- 録音・保存・送信を一切していないこと
- 「システム音声録音」の許可が要ること、その許可のしかた
- 動作を確認する手順（音楽を再生 → 一覧に出る → スライダーを動かす）

App Privacy（プライバシー情報）は「データを収集しません」で通ります。外部へ
何も送信していないためです。

### 審査を通ったら

配信が始まってから印を付けます。先にタグを打つと、リジェクトされた場合に
「タグはあるのに世に出ていない」版が残ります。

ここも自動です。tag-release ワークフローが 3 時間おきに App Store Connect を見て、
配信中になっていればタグ `v<version>` と GitHub Release を作ります
（`docs/release-flow.md`）。待たずに打ちたいときは Actions タブから手動で
実行できます。

---

## 2. App Store 版で失うもの

決めたうえでの選択ですが、記録として。

| | |
|---|---|
| 体験版 | **無し。**買う前に試せません |
| 有料アップグレード | **無し。**v2 は別アプリとして出し直すことになります |
| 手数料 | 15%（Small Business Program）または 30% |
| 審査 | 更新のたびに入ります |

引き換えに、特定商取引法の表記、EU の VAT 登録、ライセンス認証の実装と運用、
ドメイン、サーバ、メール送信 —— これらはすべて不要です。

---

## 3. 残っているリスク

サンドボックスで動いたとしても、**審査で通るかは別の問題**です。他アプリの音声を
取得する挙動は、レビュアーによっては指摘の対象になり得ます。上の審査メモで
用途を説明したうえで、指摘が来たら対話する前提で構えておいてください。
