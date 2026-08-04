# AppMixer-MacOS 基礎検討（技術フィージビリティスタディ）

> 目的: **macOS でアプリケーションごとに出力音量を変える**（Windows の音量ミキサー相当）機能を実現するための技術方式・制約・推奨アプローチ・MVP 案を整理する。

---

## 1. 課題の本質

Windows には各オーディオセッションの音量を制御する公開 API（WASAPI `ISimpleAudioVolume` など）があり、OS 標準の「音量ミキサー」でアプリごとに音量を変えられる。

**一方、macOS には「アプリごとの出力音量」を制御する公開 API が存在しない。** これが本プロジェクト最大の技術的障壁である。macOS のオーディオはすべて Core Audio (coreaudiod / HAL) を経由するが、標準では「デバイス単位」の音量しか公開されておらず、プロセス単位の出力ゲインを外部から設定する正規の手段がない。

したがって、いずれの実装方式も **「アプリの音声を一度自分たちのコードに通し、ゲインを掛けてから出力デバイスへ流し直す（あるいはミュートして再生し直す）」** という間接的なアプローチになる。これを実現している既存製品が方式選定の参考になる。

macOS は Windows (Vista以降) や Linux (PulseAudio/PipeWire) と異なり、**OS 標準のボリュームミキサー自体を持たない**。Core Audio はデバイス単位の音量 (`kAudioDevicePropertyVolumeScalar`) は公開するが、プロセス単位のゲインを設定するプロパティは存在しない。サードパーティ製品はすべて「デバイス音量の設定」ではなく「音声のインターセプト（タップ or 仮想ドライバ）」で回避している。

### 既存製品・OSS（先行事例）
| 製品 | 方式 | 備考 |
|------|------|------|
| Rogue Amoeba **SoundSource** | 旧: ACE(Audio Capture Engine) → 現: **ARK(Audio Routing Kit)** + ヘルパー常駐 | 商用。デファクト標準。**ACE は macOS 15 で完全廃止**、現在は ARK に移行 |
| **BackgroundMusic** (OSS) | 仮想オーディオデバイス (AudioServerPlugIn / `BGMDevice`) | github.com/kyleneideck/BackgroundMusic。アプリ別音量の実装リファレンス。**現役メンテ中(v0.5.0, macOS 10.13+)** |
| **BlackHole / VB-Cable / Loopback** | 仮想オーディオデバイス | ルーティング用途。音量制御そのものではないが仮想デバイス実装の参考 |

---

## 2. 実現方式の候補

### 方式A: 仮想オーディオデバイス方式（AudioServerPlugIn / HAL Plugin）
自前の仮想出力デバイスを作り、システムの既定出力デバイスに設定する。全アプリの音声が仮想デバイスに集まるので、ユーザーランドのアプリ側でプロセス別にゲインを掛け、実ハードウェアデバイスへ流し直す。

- **仕組み**: 仮想デバイスに流れ込むオーディオを、CoreAudio のクライアント情報（どのプロセスが再生中か）と突き合わせてプロセス別に処理。**BackgroundMusic は `BGMDriver` が各アプリの音声を CoreAudio のミックス前に受け取り、ドライバ内でサンプルを直接加工してアプリ別ゲインを適用**し、ループバック入力ストリームへ書き出す（真のプロセス別ゲイン）。既知の癖: ゲイン 50% 超でクリップし得る。
- **AudioServerPlugIn の位置づけ**: ユーザー空間の CoreAudio HAL プラグイン (`coreaudiod` がロード、`/Library/Audio/Plug-Ins/HAL` に配置)。Big Sur 以降は **AudioDriverKit (dext) 上に構築も可能**だが、**素の HAL バンドル形式も現役で非推奨ではない**。BackgroundMusic は kext ではなくこの HAL 仮想デバイス方式で macOS 10.13〜15 に対応。
- **長所**
  - 対応 OS が広い（古い macOS でも動く）
  - 「システム全体のミキサー」という UX を素直に実現できる
- **短所**
  - **システム拡張（System Extension / DriverKit）としての署名が必要** → Apple から DriverKit / System Extension 権限（Provisioning）の付与を受ける必要がある
  - 既定出力デバイスを自前の仮想デバイスへ差し替える必要があり、切替え・障害時のフォールバックが複雑
  - レイテンシ、フォーマット変換、排他制御などの実装難度が高い
  - **Mac App Store 配布不可**（System Extension は MAS 非対応）→ Developer ID + 公証(Notarization) 直接配布になる

### 方式B: Core Audio Process Tap 方式（macOS 14.2 / 実用は 14.4+）★推奨の起点
macOS 14.2 (2023) で追加された **Core Audio Process Tap API** を利用する。特定プロセスの音声を「タップ（捕捉）」でき、元プロセス側をミュートする挙動も指定できる。kext 不要でプリミックス（ミックス前）のプロセス別音声を得られる、初の正規手段。

- **対応バージョン**: シンボル自体は **14.2** で追加されたが、Apple の公式サンプルと安定したヘッダは **14.4** で提供された。実運用プロジェクトは信頼性のため **14.4+ を対象**にするのが一般的。
- **主要 API（AudioToolbox / CoreAudio）**
  - `CATapDescription` — タップ設定。`initStereoMixdownOfProcesses:` / `initStereoGlobalTapButExcludeProcesses:` / `initWithProcesses:andDeviceUID:withStream:`、`setMuteBehavior:`、`setPrivate:`、`setExclusive:` 等
  - `AudioHardwareCreateProcessTap()` — タップ生成（`AudioObjectID` を返す）
  - `AudioHardwareCreateAggregateDevice()` — タップをサブデバイスとして束ねる集約デバイス（`kAudioAggregateDeviceTapListKey`, `kAudioSubTapUIDKey`, `kAudioAggregateDeviceTapAutoStartKey` 等）。`IOProc` を付けてサンプルを読む
  - `CATapMuteBehavior` 列挙: `CATapUnmuted`（通常再生）/ `CATapMuted`（元を無音化）/ `CATapMutedWhenTapped`（タップ有効中のみ元を無音化）
- **⚠ 音量制御への応用（重要）**: **タップ API に「ゲイン設定」プロパティは存在しない。** 音量調整は次の手順でしか実現できない —
  1. `CATapMutedWhenTapped` を設定して元アプリの音声を出力に到達させない
  2. サンプルを捕捉し、**IOProc 内で自前のゲイン乗算を適用**
  3. 加工した音声を出力デバイス（集約デバイス / 出力 AudioUnit）へ**再レンダリング**する

  → すなわち **自分自身が「ミキサー」になる**必要がある。
- **長所**
  - **カーネル拡張・仮想ドライバ不要**（署名のハードルが方式Aより低い）
  - **ドライバ用エンタイトルメント不要**。録音同意プロンプトのみで済むため **App Store 配布との相性が最も良い**
  - 既定出力デバイスを差し替えずに済む
  - Apple 公式サンプル（"Capturing system audio with Core Audio taps"）や OSS `insidegui/AudioCap` が存在
- **短所**
  - **macOS 14.2/実用 14.4 以上が必須**（それ未満は非対応）
  - **オーディオ録音の TCC 許可プロンプト**が必要（録音インジケータが表示され得る）
  - IOProc はリアルタイム安全制約下。**タップのライフサイクル・既定デバイス変更・プロセスの起動/終了**を堅牢に扱う必要があり、多くの実装は**ヘルパー/エージェントプロセス**を用いる
  - 再レンダリングに伴うレイテンシ・ドリフト補償の管理が必要

### 方式C: ハイブリッド
14.2+ では方式B、それ未満では方式A にフォールバック。UX は統一できるが実装コストが二重になるため **MVP 段階では非推奨**。

---

## 3. 推奨アプローチ

**まず方式B（Process Tap, macOS 14.2+）で PoC を作る。**

理由:
1. 仮想ドライバ／システム拡張の署名調整（Apple への権限申請）という重い前提を初期段階で回避できる
2. Apple 公式サンプルがあり、最短で「1アプリの音量が変わる」ところまで検証できる
3. 近年の macOS ユーザーの大半が 14.2+ に到達しており、実用上のカバレッジは十分

方式B で技術的な要（レイテンシ・音質・安定性）を見極めたうえで、
「もっと広い OS 対応」や「システム全体ミキサーの UX」が必要になった段階で方式A（仮想デバイス）を追加検討する。

---

## 4. MVP スコープ案

段階的に検証する。

**Phase 0 — 環境・API 検証（PoC）**
- Swift + AudioToolbox で Process Tap を用い、**1つの指定アプリ**の音声を捕捉→ゲイン適用→出力できるか検証
- レイテンシ・音割れ・CPU 負荷を計測
- エンタイトルメント / TCC 許可フローの確認

**Phase 1 — 単一アプリ音量コントロール**
- メニューバー常駐アプリ（SwiftUI/AppKit）
- 音を出しているプロセスの列挙
- 選択したアプリの音量スライダー + ミュート

**Phase 2 — マルチアプリ・ミキサー UI**
- 複数アプリを同時に個別制御
- 設定の永続化（アプリごとの既定音量を記憶）

**Phase 3 — 配布対応**
- Hardened Runtime + 公証 (Notarization)
- Developer ID 署名、必要エンタイトルメントの整理
- （将来）方式A による OS カバレッジ拡張の是非を判断

---

## 5. 署名・配布に関する留意点

- **公証(Notarization)** と **Hardened Runtime** は方式に関わらず必須。
- **kext**（カーネル拡張）は macOS 10.15 以降非推奨のため採用しない。
- **方式B（Process Tap）**: ドライバ用エンタイトルメント不要。実行時の **録音(TCC)許可プロンプト**のみ。フルドライバが不要なため **App Store 配布との相性が最も良い**パス。
- **方式A-1（素の HAL バンドル, BackgroundMusic 型）**: **署名 + 公証(Developer ID)** が必須。`/Library/Audio/Plug-Ins/HAL` へ配置するためインストーラ/管理者権限が必要。システムレベル部品ゆえ **サンドボックス不可・Mac App Store 対象外**。
- **方式A-2（AudioDriverKit dext）**: `com.apple.developer.driverkit` 系エンタイトルメントを **Apple に申請・承認**してもらう必要がある（自動付与されない）。加えて user client アクセス許可のエンタイトルメントも必要。Developer ID 配布は公証必須。dext は制度上は App Store 配布も可能だが、実際の音声ドライバ系ユーティリティは大半が **Developer ID + 公証（非 App Store）**で配布されている。

---

## 6. 主なリスク

| リスク | 内容 | 対応方針 |
|--------|------|----------|
| OS バージョン制約 | 方式B は 14.2+ 限定 | まず 14.2+ 対象で MVP。必要なら方式A追加 |
| レイテンシ/音質 | 再レンダリングによる遅延・劣化 | Phase 0 で定量計測しゴー/ノーゴー判断 |
| 署名・権限 | System Extension 権限や公証の運用 | 方式B優先で初期リスクを低減 |
| API 変更 | Process Tap は比較的新しく将来変更の可能性 | Apple 公式サンプル追従、抽象化レイヤで吸収 |
| 権限 UX | TCC 許可でユーザーが離脱 | オンボーディングで丁寧に誘導 |

---

## 7. 次アクション

1. 検証機で macOS バージョン確認（**14.4 以上**が望ましい）
2. Apple 公式サンプル "Capturing system audio with Core Audio taps" / OSS `insidegui/AudioCap` を入手し動作確認
3. Phase 0 PoC（1アプリのゲイン変更）を実装し、レイテンシ・安定性を計測
4. 計測結果をもとに方式B継続 or 方式A併用を判断

---

## 8. 参考リンク

**Process Tap（方式B）**
- Apple 公式サンプル: Capturing system audio with Core Audio taps — https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
- insidegui/AudioCap（Swift, macOS 14.4+ のプロセス別録音サンプル）— https://github.com/insidegui/AudioCap
- 最小サンプル (sudara gist) — https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f
- 解説: CoreAudio Taps for Dummies — https://www.maven.de/2025/04/coreaudio-taps-for-dummies/
- 解説: Recall.ai — CoreAudio Taps deep dive — https://www.recall.ai/blog/core-audio-taps

**仮想デバイス（方式A）**
- kyleneideck/BackgroundMusic — https://github.com/kyleneideck/BackgroundMusic （`DEVELOPING.md` に実装解説）
- Rogue Amoeba ACE レガシー / ARK — https://rogueamoeba.com/support/knowledgebase/?showArticle=ACE-Legacy&product=SoundSource
- Apple WWDC21: Create audio drivers with DriverKit — https://developer.apple.com/videos/play/wwdc2021/10190/
- Apple WWDC19: System Extensions and DriverKit — https://developer.apple.com/videos/play/wwdc2019/702/

**参考記事**
- macOS Still Has No Volume Mixer, So I Built One — https://dev.to/thalesbmc/macos-still-has-no-volume-mixer-so-i-built-one-53lp

---

*本ドキュメントは基礎検討フェーズの成果物であり、実装方針は PoC の計測結果に基づき更新する。*
