# AppMixer

**macOS でアプリケーションごとに音量を変える、メニューバー常駐のボリュームミキサー。**

Windows には「音量ミキサー」があり、アプリごとに音量を変えられます。macOS には
これに相当する標準機能がありません。AppMixer はそれを埋めます。

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/mixer-dark.svg">
    <img src="docs/images/mixer-light.svg" width="420" alt="AppMixer のミキサー画面。マスター音量と、アプリごとの音量スライダー・レベルメーター・出力先が並んでいる">
  </picture>
</p>

<p align="center"><sub>
  UI レイアウト図（実装に合わせて <code>docs/images/make_mockup.py</code> で生成）
</sub></p>

> **ビルド・実行には macOS 14.4 以降の実機が必要です。**

---

## 主な機能

| | |
|---|---|
| **アプリ別の音量・ミュート** | 再生中のアプリを一覧し、それぞれ独立して音量を変えられます |
| **ライブレベルメーター** | 各アプリが実際に出している音量をリアルタイム表示（約30fps） |
| **出力デバイスごとの音量記憶** | 「Spotify × AirPods = 30%」「Spotify × スピーカー = 70%」を別々に記憶し、デバイスを挿し替えると自動で切り替わります |
| **アプリ別の出力先** | 「音楽はスピーカー、通話はヘッドフォン」のような振り分け |
| **通話中の自動ダッキング** | 会議が始まったらメディアを自動で絞り、終わったら戻します |
| **マスター音量・全体ミュート** | 既定の出力デバイスそのものを操作。F11/F12 の変更にも追従します |
| **ログイン時に起動** | メニューバー常駐アプリとして自動起動 |
| **検索・全アプリ表示** | 名前で絞り込み。停止中のアプリも表示できます |

音量の増減は約80msかけて滑らかにフェードするため、操作しても「プチッ」というノイズが出ません。

---

## 動作要件

- **macOS 14.4 以降** — Core Audio の Process Tap API を使うため
- **Xcode 15.3 以降**（macOS 14.4 SDK）と Command Line Tools
- **「システム音声録音」の許可**
  - システム設定 → プライバシーとセキュリティ → システム音声録音
  - ※マイクの許可ではありません。録音インジケータ（紫の点）は点きません

---

## インストール

```bash
git clone https://github.com/iam74k4/AppMixer-MacOS.git
cd AppMixer-MacOS
make run
```

`make run` はビルド → `dist/AppMixer.app` の生成 → 署名 → 起動までを行います。
初回起動時に「システム音声録音」の許可を求められるので、**許可**してください。
（許可の反映を確実にするため、許可後に一度終了して `make run` で再起動してください。）

### 常用する場合は署名 ID を固定する

macOS の許可（TCC）とログイン項目の登録は**コード署名に紐づきます**。既定の ad-hoc 署名
だとビルドのたびに署名が変わり、そのたびに許可を求められます。

1. キーチェーンアクセス → 証明書アシスタント → 証明書を作成
   （名前: `AppMixer Dev`、種別: **コード署名**、自己署名）
2. その ID を指定してビルド:

```bash
make run IDENTITY="AppMixer Dev"
```

`dist/` は再ビルドで作り直されるため、常用するなら `/Applications` に置いてから
「ログイン時に起動」を有効にするのが安定します。

---

## 使い方

メニューバーの 🎚 アイコンをクリックするとミキサーが開きます。

- **スライダー** — そのアプリの音量。真下のバーが実際の出力レベル
- **🔊 ボタン** — そのアプリだけミュート
- **🔈 アイコン** — そのアプリの出力先を選択（既定の出力に戻すことも可能）
- **設定** — 自動ダッキングとログイン起動の設定を開閉

### 自動ダッキングについて
次のいずれかで発動します。

- **会議アプリが音を出した** — Zoom / Teams / Meet / Webex / FaceTime / Chime
- **マイクが使われた**（任意・既定でオン）— どの通話アプリでも拾えます

Discord や Slack は**通知音のたびに音楽が下がってしまう**ため、出音では発動させず
マイク検知に任せています。また通話アプリ自身は絞りません（相手の声が小さくなるため）。

### アプリ名の表示について
Edge / Chrome / Discord などは音声を**ヘルパープロセス**から出すため、素朴に列挙すると
`com.microsoft.edge.helper` のような名前になります。AppMixer は親プロセスを辿って
**本体アプリの名前とアイコンに解決**し、同じアプリの複数ヘルパーを 1 行にまとめます。

---

## 仕組み

macOS には「アプリの音量を設定する API」が存在しません。そのため AppMixer は
**アプリの音声を一度自分に通し、ゲインを掛けて出力し直す**という方法をとっています。

1. 対象アプリに **Process Tap** を張り、`.mutedWhenTapped` で元の出力を止める
2. 出力デバイスとタップを束ねた**プライベート集約デバイス**を作る
3. その **IOProc** で音量を掛け、ピークを計測して出力へ書き戻す

つまり AppMixer 自身がミキサーになります。方式選定の経緯は次のドキュメントに詳しくあります。

- [`docs/feasibility-study.md`](docs/feasibility-study.md) — 技術フィージビリティ検討
- [`docs/approach-comparison.md`](docs/approach-comparison.md) — 仮想デバイス方式との比較

---

## 既知の制約

- **macOS 14.4 以降が必要**です。それ以前の OS に対応するには仮想オーディオデバイス
  （方式A）の実装が別途必要になります
- **多チャンネル出力デバイス**（HDMI・AVアンプ・オーディオIF など）では、タップと出力の
  フォーマットが一致しない場合に音量調整を行いません。誤った音を出すより安全側に倒しています
- タップ API 側の既知の挙動として、多チャンネルデバイスでは**減衰量が約 −12dB ずれる**
  ことが報告されています
- **増幅（100%超）は未対応**です。クリップを避けるため 0〜100% に制限しています
- Core Audio のリアルタイム処理を含むため、**環境ごとの検証・調整が前提**です

---

## 開発

### ビルド

```bash
make build   # ビルドのみ
make bundle  # .app を生成
make sign    # 署名まで
make run     # 起動まで
make clean
```

### ブランチ運用

- `main` — リリース済みの安定版
- `develop` — 統合ブランチ（**直接コミットしない**）
- 作業ブランチ — 必ず `develop` から切り、完了後に `develop` へマージ
  （`feature/` `fix/` `docs/` `chore/`）

コミットメッセージは Conventional Commits（`feat:` `fix:` `docs:` `chore:` など）に統一しています。

### 構成

```
Package.swift                  SwiftPM 実行ターゲット
Makefile                       ビルド・バンドル生成・署名・起動
bundle/                        Info.plist / エンタイトルメント
Sources/AppMixer/
  AppMixerApp.swift            エントリポイント（MenuBarExtra）
  ContentView.swift            ミキサー全体のレイアウト
  AppRowView.swift             アプリ 1 行分の UI
  MixerModel.swift             画面と音声エンジンの仲介・永続化
  MixerController.swift        音量状態・タップの生成破棄・デバイス追従
  ProcessTap.swift             Process Tap と IOProc（ゲイン適用・レベル計測）
  AudioApp.swift               音声プロセスをアプリ単位に集約
  ProcessIdentity.swift        ヘルパープロセス → 本体アプリの解決
  AudioDevice.swift            出力デバイスの列挙
  DuckingDetector.swift        通話中かどうかの判定
  AudioCapturePermission.swift システム音声録音の許可
  LaunchAtLogin.swift          ログイン時の自動起動
  CoreAudioObject.swift        Core Audio プロパティ read/write ヘルパー
docs/                          設計ドキュメント
```

---

## ロードマップ

**実装済み**
アプリ別音量・ミュート / ライブメーター / マスター音量 / デバイスごとの音量記憶 /
アプリ別の出力先 / 自動ダッキング / 滑らかなフェード / 検索・全アプリ表示 / ログイン時に起動

**検討中**
- 集約デバイスの統合（アプリごとに作っている集約デバイスを 1 つにまとめ、音飛び・CPU・電力を改善）
- 多チャンネル出力デバイスへの対応
- ソロ（1 アプリだけ残して他をミュート）
- 安全な増幅（リミッター付きで 100% 超を解禁）
- ナイトモード（夜間向けの音圧圧縮）／ スリープタイマー

---

## 参考

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps) — Apple 公式サンプル
- [insidegui/AudioCap](https://github.com/insidegui/AudioCap) — Process Tap の実装リファレンス
- [kyleneideck/BackgroundMusic](https://github.com/kyleneideck/BackgroundMusic) — 仮想デバイス方式の実装

その他の参考資料は [`docs/approach-comparison.md`](docs/approach-comparison.md) にまとめています。
