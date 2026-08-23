# リリースフロー

`develop` を `main` へマージすると、そこから先は自動で進む。ビルド、署名、
App Store Connect へのアップロード、審査への提出、配信後のタグ打ちまで、
人が押すボタンは無い。App Store 提出そのものの背景（サンドボックス、審査メモ、
失うもの）は `docs/app-store.md` を参照。

---

## 全体像

```
develop で開発
   │  バージョンを上げ、CHANGELOG を整える
   ▼
PR: develop → main ─ マージ ─▶ release.yml
                                  │
                                  ├─ upload (macOS)
                                  │    make mas で .pkg を作り、
                                  │    App Store Connect へ送る
                                  │
                                  └─ submit (Linux)
                                       ビルドの処理を待ち、
                                       バージョンを作り、
                                       CHANGELOG をリリースノートに入れ、
                                       審査に提出する
                                  ▼
                              Apple の審査
                                  │  通れば自動で配信開始（AFTER_APPROVAL）
                                  ▼
                            tag-release.yml（3 時間おき）
                               配信中を見つけたら
                               タグ v<version> と GitHub Release を作る
```

| 誰が | 何を |
|---|---|
| 自動（release.yml / upload） | ビルド、署名、.pkg 作成、アップロード |
| 自動（release.yml / submit） | 処理待ち、バージョン作成、リリースノート、**審査への提出** |
| 自動（tag-release.yml） | 配信を検知してタグと GitHub Release を作成 |
| 人 | バージョンを上げる、CHANGELOG を書く、リジェクトされたときの対応 |

タグを最後に打つのは `docs/app-store.md` の方針どおり。リジェクトされた場合に
「タグはあるのに世に出ていない」版を残さないため。

### 二重に出さないための歯止め

- `main` のバージョンに対応するタグが既にあれば、release.yml は何もしない。
  リリース後にドキュメント修正だけを main へ入れても、二重アップロードは起きない。
- 同じバージョンが App Store Connect で既に配信中なら、submit ジョブは
  「バージョンを上げてください」と言って止まる。
- tag-release.yml はタグが既にあれば即座に終わる。

---

## 一度だけの準備

### 1. Apple 側で作るもの

`docs/app-store.md` の「Apple 側で用意するもの」のとおり。CI で使うのはこの 3 つ。

| もの | 用途 |
|---|---|
| **Apple Distribution** 証明書 | .app の署名 |
| **3rd Party Mac Developer Installer** 証明書 | .pkg の署名 |
| プロビジョニングプロファイル（Mac App Store 用） | .app に埋め込む |

証明書はキーチェーンアクセスで**秘密鍵ごと** .p12 に書き出す（証明書を右クリック →
書き出す → .p12、パスワードを付ける）。

### 2. App Store Connect API キーを作る

App Store Connect → **ユーザとアクセス** → **統合**（Integrations）→
**App Store Connect API** → チームキー → **+**。

- ロールは **App Manager**。アップロードだけなら Developer でも足りるが、
  審査への提出とバージョンの作成には App Manager が要る
- 作成すると **Issuer ID** と **キー ID** が表示され、**.p8 ファイルは一度しか
  ダウンロードできない**。安全な場所に保管する

### 3. GitHub Secrets に入れる

リポジトリの Settings → Secrets and variables → Actions → New repository secret。

| Secret 名 | 中身 |
|---|---|
| `MAS_CERT_P12` | Apple Distribution の .p12 を base64 にしたもの |
| `MAS_INSTALLER_CERT_P12` | Installer 証明書の .p12 を base64 にしたもの |
| `CERT_P12_PASSWORD` | 上の 2 つの .p12 に付けたパスワード（共通にしておく） |
| `MAS_IDENTITY` | `Apple Distribution: <名前> (<TEAMID>)` |
| `MAS_INSTALLER_IDENTITY` | `3rd Party Mac Developer Installer: <名前> (<TEAMID>)` |
| `PROVISION_PROFILE_B64` | .provisionprofile を base64 にしたもの |
| `ASC_API_KEY_ID` | API キーのキー ID（例 `2X9R4HXF34`） |
| `ASC_API_ISSUER_ID` | Issuer ID（UUID 形式） |
| `ASC_API_KEY_P8` | .p8 ファイルの中身そのまま（テキスト） |

base64 化はローカルで:

```bash
base64 -i distribution.p12 | pbcopy         # Secret に貼り付け
base64 -i AppMixer.provisionprofile | pbcopy
```

### 4. 振る舞いを変えたいとき（Variables、任意）

同じ画面の **Variables** タブで設定する。既定のままでよければ何もしなくてよい。

| 変数名 | 既定 | 効果 |
|---|---|---|
| `ASC_AUTO_SUBMIT` | （未設定 = 提出する） | `false` にすると、アップロードだけして審査に出さない |
| `ASC_RELEASE_TYPE` | `AFTER_APPROVAL` | `MANUAL` にすると、審査を通っても自分で配信開始を押すまで公開されない |

`ASC_RELEASE_TYPE=MANUAL` にした場合、審査通過後に App Store Connect で
「このバージョンをリリース」を押すまで配信は始まらない。tag-release.yml は
配信が始まるまでタグを打たないので、押し忘れるとタグも付かない。

### 5. App Store Connect（Web）でしかできない初回設定

- アプリレコードの作成、価格設定、App Privacy の回答
- スクリーンショットと説明文
- 契約・税金・口座情報

ここが済んでいないと、submit ジョブはバージョンを作れずに止まる。

設定できたら、main へマージする前に Actions タブ → release → **Run workflow** で
疎通確認ができる。「審査に出すところまでやる」のチェックを外せば、アップロードだけ
試せる。

---

## 毎回のリリース手順

人がやるのは 2 つだけ。

1. **develop で仕上げる**
   - `bundle/Info.plist` の `CFBundleShortVersionString` を上げる
     （ビルド番号は Makefile が導出するので触らない）
   - `CHANGELOG.md` の「未リリース」を新しいバージョン見出しに移し、日付を入れる。
     **この節がそのまま App Store のリリースノートと GitHub Release の本文になる**
   - `make run-sandboxed` でサンドボックス動作を確認する（`docs/app-store.md` 参照）
2. **PR: develop → main を作ってマージする**

あとは待つ。審査に通れば配信が始まり、3 時間以内に tag-release.yml が
`v<version>` のタグと GitHub Release を作る。

### リジェクトされたら

自動では何も起きない（`DEVELOPER_REJECTED` などの状態で止まり、tag-release.yml は
タグを打たない）。直したうえで、パッチバージョンを上げて develop → main を
やり直すのが素直。App Store Connect で直接返答して解決した場合は、配信が始まれば
tag-release.yml がタグを打つので、こちらで何かする必要はない。

---

## 中身

### `scripts/asc.py`

App Store Connect API を叩く小さな道具。3 つの操作だけを持つ。

| 操作 | 何をするか |
|---|---|
| `wait-build` | アップロードしたビルドの処理（`processingState`）が `VALID` になるのを待つ |
| `submit` | バージョンを作り、ビルドを紐づけ、リリースノートを入れ、審査に出す |
| `state` | いまそのバージョンがどう扱われているかを表示する（`--require-live` で判定にも使う） |

認証は API キーから作る ES256 の JWT。依存は PyJWT だけで、HTTP は標準ライブラリ。
fastlane を持ち込むと metadata ディレクトリ一式をリポジトリで管理することになるため、
必要な部分だけを自前で持っている。

審査への提出は 3 手に分かれている（入れ物を作る → バージョンを入れる →
`submitted=true` にする）。最後の一手を忘れると「作ったのに出ていない」状態になるので、
手で API を叩くときは注意する。

### `scripts/changelog-section.sh`

`CHANGELOG.md` から `## [X.Y.Z]` の節だけを取り出す。App Store のリリースノートと
GitHub Release の本文の両方がこれを使う。二か所で別々に書くと食い違うため。

### cron の注意

`tag-release.yml` の `schedule` は、**このリポジトリの既定ブランチ（`main`）に
あるファイル**で動く。ワークフローを直したら、main に入るまで反映されない。
develop へマージしただけでは、次のリリースで main に入るまで古い定義のまま動く。

また GitHub は、60 日間まったく動きの無いリポジトリで scheduled workflow を
自動的に止める。長く触っていない状態でリリースしたときは、Actions タブで
有効になっているかを確認する（止まっていても、tag-release は手動実行できる）。

---

## この先やれること

| やれること | 手段 |
|---|---|
| 審査結果を Slack / メールに流す | `scripts/asc.py state` を cron で回して通知する |
| 審査状態の変化を待たずに拾う | App Store Connect の Webhook（公開 URL の受け口が要る） |
| スクリーンショットや説明文もリポジトリで管理する | fastlane `deliver` に寄せる |
| 段階的リリース（Phased Release） | `appStoreVersionPhasedReleases` を叩く |

Webhook を使えば 3 時間おきの巡回は要らなくなるが、受け口となる公開の HTTPS
エンドポイントが必要で、GitHub の `repository_dispatch` は認証ヘッダを求めるため
そのままでは繋がらない。中継を 1 つ立てるだけの価値が出るのは、リリース頻度が
上がってから。

### altool が使えなくなったら

`altool` は非推奨扱いが続いており、いずれ Xcode から消える可能性がある。
乗り換え先（どちらも同じ API キーで動く）:

- **fastlane**（GitHub の macOS ランナーに同梱）:

  ```bash
  fastlane deliver --pkg "dist/AppMixer-<version>.pkg" --platform osx \
    --skip_screenshots --skip_metadata \
    --api_key_path asc_key.json
  ```

- **App Store Connect の Build Upload API**（REST）を直接呼ぶ

差し替えるのは release.yml の「App Store Connect へアップロード」ステップだけで、
submit 以降はそのまま使える。

---

## 関連ファイル

- `.github/workflows/release.yml` — main マージでアップロードし、審査に出す
- `.github/workflows/tag-release.yml` — 配信を検知してタグと GitHub Release を作る
- `.github/workflows/build.yml` — 通常のビルド確認 CI
- `scripts/asc.py` — App Store Connect API を叩く道具
- `scripts/changelog-section.sh` — CHANGELOG から該当バージョンの節を取り出す
- `Makefile` — `make mas` が提出物を作る本体
- `docs/app-store.md` — App Store 提出の背景と審査まわり
