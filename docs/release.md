# リリース手順

配布物は **Developer ID 署名 + 公証済みの zip** です。以下は macOS 実機で行います。

---

## 事前に一度だけ必要なもの

| | 用途 | 備考 |
|---|---|---|
| **Apple Developer Program** | Developer ID 証明書の発行 | 年額 $99。個人でも可 |
| **Developer ID Application 証明書** | 配布用の署名 | Xcode → Settings → Accounts から作成し、キーチェーンに入れる |
| **App用パスワード** | 公証（notarytool）の認証 | appleid.apple.com で発行 |

公証の資格情報をキーチェーンに保存します（毎回入力しなくて済むように）。

```bash
xcrun notarytool store-credentials AppMixerNotary \
  --apple-id "<Apple ID>" \
  --team-id "<TEAMID>" \
  --password "<App用パスワード>"
```

署名 ID の正確な名前は次で確認できます。

```bash
security find-identity -v -p codesigning
```

---

## リリース手順

### 1. develop で動作を確認する

```bash
git checkout develop && git pull
make run
```

最低限、次を実機で確認します。

- [ ] ビルドが通る
- [ ] アプリ一覧に正しい名前とアイコンが出る
- [ ] 音量スライダーとミュートが効く
- [ ] レベルメーターが動く
- [ ] 出力デバイスを挿し替えると、そのデバイス用の音量に切り替わる
- [ ] アプリ別の出力先を変更できる／振り分け先を抜いても無音にならない
- [ ] 自動ダッキングが発動し、通話終了で元に戻る
- [ ] 終了したあと、音量を変えていたアプリの音が元に戻る

### 2. バージョンを上げる

`bundle/Info.plist` の 2 か所を更新します（Makefile はここからバージョンを読みます）。

- `CFBundleShortVersionString` … 表示用（例 `0.1.0`）
- `CFBundleVersion` … ビルド番号。リリースごとに必ず増やす

`CHANGELOG.md` の「未リリース」を新しいバージョン見出しに移し、日付を入れます。

### 3. main へ入れてタグを打つ

```bash
git checkout main
git merge --no-ff develop
git push origin main
git tag v0.1.0
git push origin v0.1.0
```

### 4. 配布物を作る

```bash
make release \
  IDENTITY="Developer ID Application: <名前> (<TEAMID>)" \
  KEYCHAIN_PROFILE=AppMixerNotary
```

`dist/AppMixer-<version>.zip` ができます。`make release` は次を行います。

1. ビルドと `.app` の組み立て（アイコンの `.icns` 生成を含む）
2. Hardened Runtime + セキュアタイムスタンプ付きで署名
3. zip 化して公証へ提出し、完了を待つ
4. チケットを `.app` に添付（staple）して zip を作り直す
5. `spctl` で Gatekeeper の判定を表示

### 5. 公開する

GitHub の Releases でタグ `v0.1.0` を選び、`CHANGELOG.md` の該当部分を本文にして
`dist/AppMixer-<version>.zip` を添付します。

---

## 確認しておくとよいこと

**別のマシンで開けるか。** 公証が効いていれば、初回起動で「開発元を検証できません」
と言われずに起動します。手元の Mac は署名した本人なので気づけません。

```bash
# ダウンロード済みファイルと同じ扱いにして試す
xattr -w com.apple.quarantine "0081;00000000;Safari;" dist/AppMixer-0.1.0.zip
```

**許可のリセット。** 初回起動時の挙動を試すときに使います。

```bash
tccutil reset AudioCapture com.appmixer.macos
```

---

## うまくいかないとき

| 症状 | 原因と対処 |
|---|---|
| `make dist` が「Developer ID が要ります」で止まる | `IDENTITY` が ad-hoc（既定）のまま。証明書の正式名を渡す |
| 公証が `Invalid` で返る | `xcrun notarytool log <submission-id> --keychain-profile ...` で理由を見る。Hardened Runtime かタイムスタンプの欠落が多い |
| 起動時に「開発元を検証できません」 | 公証か staple が済んでいない。`spctl --assess --type execute -vv dist/AppMixer.app` で確認 |
| 起動しても音量が変わらない | システム音声録音が未許可。システム設定 → プライバシーとセキュリティ → システム音声録音 |
