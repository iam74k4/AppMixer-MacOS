# AppMixer-MacOS

macOS でアプリケーションごとに出力音量を変える、メニューバー常駐アプリ（Windows の音量ミキサー相当）。

実現方式は **方式B: Core Audio Process Tap**（macOS 14.4+）。設計の背景は
[`docs/feasibility-study.md`](docs/feasibility-study.md) と
[`docs/approach-comparison.md`](docs/approach-comparison.md) を参照。

> ⚠️ このリポジトリは Linux 環境でも編集できますが、**ビルド・実行は macOS 実機**（14.4 以上）が必要です。

---

## 動作要件

- **macOS 14.4 以降**（Process Tap API と `NSAudioCaptureUsageDescription` のため）
- **Swift 5.9+ / Xcode Command Line Tools**（`swift`, `codesign`, `make`）
- 「システム音声録音（System Audio Recording / `kTCCServiceAudioCapture`）」の許可
  - ※マイク許可ではありません。紫のマイクインジケータは点きません。

---

## ビルドと起動（最短）

```bash
# リポジトリ直下で
make run
```

これで以下が実行されます:
1. `swift build -c release` で実行ファイルをビルド
2. `dist/AppMixer.app` として `.app` バンドルを生成（`Info.plist` 同梱）
3. エンタイトルメント付きで署名（既定は ad-hoc）
4. `open` で起動 → メニューバーに **スライダーアイコン** が表示される

初回起動時に **「AppMixer にシステム音声録音を許可しますか？」** のダイアログが出ます。**許可**してください。
（許可後は macOS の仕様上、一度アプリを終了して再度 `make run` すると確実に反映されます。）

---

## 使い方

1. メニューバーの `slider.vertical.3` アイコンをクリック
2. **いま音を出しているアプリ**が一覧表示される（例: Music, Safari, Chrome…）
3. 各行の**スライダー**でそのアプリの音量を変更、**🔊ボタン**でミュート
   - 100% のときはタップを張らず通常再生（低負荷）
   - 100% 未満／ミュート時にだけ Process Tap が起動し、音量を適用

---

## 動作確認の手順

1. 音楽アプリ（Music など）で再生を始める
2. メニューを開き、その行のスライダーを 50% に下げる → **音量が下がる**
3. ミュートボタンを押す → **無音になる**（他アプリの音はそのまま）
4. スライダーを 100% に戻す → **原音に戻り、タップが破棄される**
5. 出力デバイス（スピーカー↔ヘッドフォン）を切り替えても、下げた音量が維持されることを確認

---

## TCC 許可を再ビルド後も維持したい場合（推奨）

ad-hoc 署名（`IDENTITY=-`）だと**ビルドの度にコード署名が変わり**、TCC 許可が毎回リセットされます。
開発を繰り返すなら、安定した自己署名証明書を使うと許可が維持されます。

1. キーチェーンアクセス →「証明書アシスタント」→「証明書を作成」
   - 名前: `AppMixer Dev`、種別: **コード署名**、自己署名
2. 署名 ID を指定してビルド:

```bash
make run IDENTITY="AppMixer Dev"
```

---

## トラブルシューティング

| 症状 | 対処 |
|------|------|
| メニューに「許可が必要です」と出る | メニューの「システム設定を開く…」→ プライバシーとセキュリティ → システム音声録音 で AppMixer を ON |
| 許可したのに反映されない | アプリを終了し `make run` で再起動（TCC は新規プロセスにのみ適用） |
| スライダーを下げても変化しない | 対象アプリが実際に出力中か確認。多チャンネルI/Fでは減衰量がずれる既知の挙動あり（下記） |
| 再ビルドの度に許可を聞かれる | 上記「安定した署名 ID」を使用 |

---

## 既知の制約・注意

- **macOS 14.4+ 限定**（旧 OS 非対応。旧 OS 対応は方式A=仮想デバイスが必要）。
- Process Tap には**ゲイン設定 API が無い**ため、`.mutedWhenTapped` で元音を止め、
  IOProc で自前ゲインを掛けて再レンダリングしている（＝自分がミキサーになる）。
- 4ステレオペア（8ch）等の**多チャンネル出力デバイスでは減衰量が約 −12dB ずれる**という
  タップ API 側の既知挙動がある（Apple Forums）。必要なら実測して補正する。
- 100% 超の増幅は可能だが**クリップ**しうるため、UI は 0〜100% に制限している。
- 本コードは Core Audio のリアルタイム処理を含み、**実機での検証・微調整前提**の PoC 段階です。

---

## 構成

```
Package.swift                     SwiftPM 実行ターゲット定義
Makefile                          .app バンドル生成・署名・起動
bundle/Info.plist                 NSAudioCaptureUsageDescription / LSUIElement など
bundle/AppMixer.entitlements      audio-input エンタイトルメント（ローカル開発用）
Sources/AppMixer/
  main.swift                      エントリポイント（メニューバー常駐）
  AppDelegate.swift               ステータスアイテム・メニュー構築・権限フロー
  AppVolumeItemView.swift         アプリ1行分の UI（アイコン/名前/スライダー/ミュート）
  MixerController.swift           音量状態管理・タップの生成/破棄・既定デバイス追従
  ProcessTap.swift                Process Tap + 集約デバイス + IOProc（ゲイン適用）
  AudioProcess.swift              出力中プロセスの列挙モデル
  AudioCapturePermission.swift    kTCCServiceAudioCapture の状態確認/要求
  CoreAudioObject.swift           AudioObjectID プロパティ読み取りヘルパー
docs/                             基礎検討・方式比較ドキュメント
```

---

## 参考

参考にした実装・資料は `docs/approach-comparison.md` の参考リンク、および
Apple サンプル "Capturing system audio with Core Audio taps"、`insidegui/AudioCap` 等。
