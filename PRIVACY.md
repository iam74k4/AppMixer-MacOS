# プライバシーポリシー / Privacy Policy

**AppMixer**

最終更新日 / Last updated: 2026-08-22

---

## 日本語

### 収集する情報

**AppMixer は、いかなる個人情報も収集、保存、送信しません。**

本アプリには、解析ツール、広告ネットワーク、クラッシュレポート送信機能、その他のサードパーティ製 SDK が一切含まれていません。外部サーバーとの通信機能を持ちません。

### 音声の取り扱い

AppMixer は、アプリごとの音量を調整するという目的のためだけに、macOS の Core Audio が提供する Process Tap 機能を用いて、お使いの Mac 上で再生されている音声を経由させます。

この音声は、**録音・保存・送信のいずれも行いません。** 音量の調整と、画面に表示するレベルメーターの描画のために、お使いの Mac のメモリ上でのみ処理され、直ちに破棄されます。

### 保存される設定

アプリごとの音量、ミュートの状態、出力先の割り当てといった設定は、macOS の標準的な仕組み（`UserDefaults`）を用いて、お使いの Mac の内部にのみ保存されます。これらが外部に送信されることはありません。

App Sandbox が有効なため、保存先は本アプリ専用のコンテナ領域に限定されます。

### アプリの削除

AppMixer を削除すると、上記の設定も併せて削除されます。

### お問い合わせ

本ポリシーに関するご質問は、GitHub リポジトリの Issues までお寄せください。

https://github.com/iam74k4/AppMixer-MacOS/issues

---

## English

### Information We Collect

**AppMixer does not collect, store, or transmit any personal information.**

This application contains no analytics tools, no advertising networks, no crash reporting, and no third-party SDKs of any kind. It has no capability to communicate with external servers.

### How Audio Is Handled

For the sole purpose of adjusting per-application volume, AppMixer routes audio playing on your Mac using the Process Tap facility provided by macOS Core Audio.

This audio is **never recorded, never stored, and never transmitted.** It is processed only in memory on your own Mac — to apply volume adjustments and to draw the on-screen level meters — and is discarded immediately thereafter.

### Settings We Store

Your settings — per-application volume levels, mute states, and output device assignments — are stored only on your own Mac using the standard macOS mechanism (`UserDefaults`). They are never transmitted anywhere.

Because App Sandbox is enabled, this storage is confined to a container reserved for this application.

### Deleting the App

Removing AppMixer also removes the settings described above.

### Contact

Questions about this policy may be raised via Issues on the GitHub repository.

https://github.com/iam74k4/AppMixer-MacOS/issues
