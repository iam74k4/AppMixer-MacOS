# リリースフロー

`main` へマージすると App Store Connect へビルドが自動アップロードされる仕組みと、
その前後で人がやることをまとめる。App Store 提出そのものの背景（サンドボックス、
審査メモ、失うもの）は `docs/app-store.md` を参照。

---

## 全体像

```
develop で開発
   │  バージョンを上げ、CHANGELOG を整える
   ▼
PR: develop → main ─ マージ ─▶ GitHub Actions (release.yml)
                                  │  make mas で .pkg を作り、
                                  │  App Store Connect API キーでアップロード
                                  ▼
                            App Store Connect
                                  │  （人）ビルドを選び、審査に提出
                                  ▼
                              審査 → 配信開始
                                  │  （人）配信を確認したら
                                  ▼
                    GitHub Actions (tag-release.yml) を手動実行
                       タグ v<version> と GitHub Release を作成
```

役割分担は次のとおり。

| 誰が | 何を |
|---|---|
| 自動（release.yml） | ビルド、署名、.pkg 作成、App Store Connect へのアップロード |
| 人（App Store Connect の Web） | 審査への提出、リリースノート等のメタデータ、配信確認 |
| 自動（tag-release.yml、人が起動） | タグ打ちと GitHub Release の作成 |

タグを最後に打つのは `docs/app-store.md` の方針どおり。リジェクトされた場合に
「タグはあるのに世に出ていない」版を残さないため。

同じバージョンのタグが既にあるときは release.yml はアップロードせずに終わる。
そのため、リリース後にドキュメント修正だけを main へ入れても二重アップロードは
起きない。同じバージョンを出し直したいとき（アップロード後に不備が見つかった等）は
`bundle/Info.plist` は変えずに再マージすればよいが、App Store はビルド番号の重複を
弾くので、その場合は一度 Web の Transporter 経由で `BUILD_NUMBER=<数値>` を渡した
手動ビルドにするか、パッチバージョンを上げるのが簡単。

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

- ロールは **App Manager**（アップロードに必要な最小ロール）
- 作成すると **Issuer ID** と **キー ID** が表示され、**.p8 ファイルは一度しか
  ダウンロードできない**。安全な場所に保管する

このキーは Web の操作（審査提出やメタデータ編集）を将来自動化するときにも
そのまま使える（後述）。

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

設定できたら、main へマージする前に Actions タブ → release → **Run workflow** で
疎通確認ができる（署名とアップロードまで実際に走るので、出したくない版のときは
やらないこと）。

---

## 毎回のリリース手順

1. **develop で仕上げる**
   - `bundle/Info.plist` の `CFBundleShortVersionString` を上げる
     （ビルド番号は Makefile が導出するので触らない）
   - `CHANGELOG.md` の「未リリース」を新しいバージョン見出しに移し、日付を入れる
   - `make run-sandboxed` でサンドボックス動作を確認する（`docs/app-store.md` 参照）
2. **PR: develop → main** を作ってマージする
   - マージで release.yml が走り、App Store Connect にビルドが上がる
3. **App Store Connect（Web）で審査に提出する**
   - 処理が終わったビルドを新しいバージョンに紐づけ、リリースノートを書き、提出
   - 審査メモの書き方は `docs/app-store.md` の「審査に出すときに書くこと」
4. **配信が始まったら** Actions タブ → tag-release → **Run workflow**
   - `v<version>` のタグと、CHANGELOG の該当節を本文にした GitHub Release ができる

---

## App Store Connect API でできること・できないこと

いま自動化しているのは**ビルドのアップロード**だけ（release.yml が
`xcrun altool --upload-app` を API キー認証で呼ぶ）。同じキーで、必要になれば
ここまで広げられる。

| できること | 手段 |
|---|---|
| ビルドのアップロード | altool / Transporter / REST（2025 年から Build Upload API が公式に追加） |
| バージョン作成・リリースノート等のメタデータ更新 | REST API、または fastlane `deliver` |
| 審査への提出・リリース方式（手動/自動/段階的）の設定 | REST API、fastlane `deliver` |
| 審査状況の取得（通知の自動化など） | REST API |
| 売上・ダウンロードレポートの取得 | REST API |

Web でしかできないこと（自動化の対象外）:

- 初回のアプリレコード作成、価格設定、App Privacy の回答
- 契約・税金・口座情報
- スクリーンショットの初回整備（API でも更新はできるが、初回は Web が早い）

**次の一手として現実的なのは「審査提出まで自動化」**。fastlane `deliver` に
API キーを渡せば、アップロード済みビルドの紐付け → リリースノート反映 →
提出までを 1 コマンドにできる。ただし審査メモやスクリーンショットの管理を
リポジトリに持ち込むことになるので、リリース頻度が上がってから考えれば十分。

### altool が使えなくなったら

`altool` は非推奨扱いが続いており、いずれ Xcode から消える可能性がある。
その場合の乗り換え先（どちらも同じ API キーで動く）:

- **fastlane**（GitHub の macOS ランナーに同梱）:

  ```bash
  fastlane deliver --pkg "dist/AppMixer-<version>.pkg" --platform osx \
    --skip_screenshots --skip_metadata \
    --api_key_path asc_key.json
  ```

- **App Store Connect の Build Upload API**（REST）を直接呼ぶ

---

## 関連ファイル

- `.github/workflows/release.yml` — main マージでアップロード
- `.github/workflows/tag-release.yml` — 配信開始後のタグ打ち（手動起動）
- `.github/workflows/build.yml` — 通常のビルド確認 CI
- `Makefile` — `make mas` が提出物を作る本体
- `docs/app-store.md` — App Store 提出の背景と審査まわり
