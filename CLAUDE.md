# AppMixer-MacOS

macOS でアプリケーションごとに出力音量を変える（Windows の音量ミキサー相当）アプリ。

## Git 運用ルール（統一）

### ブランチ戦略（リポジトリ共通ルール）
- **`main`**: リリース済みの安定版のみ。
- **`develop`**: 統合ブランチ。すべての作業の統合先（GitFlow）。**develop へ直接コミットしない。**
- **作業ブランチ**: **必ず `develop` から切る**。完了後に `develop` へマージ（PR）する。
  - 命名例: `feature/<概要>`, `fix/<概要>`, `docs/<概要>`, `chore/<概要>`
  - 例: `git checkout develop && git pull && git checkout -b docs/approach-comparison`

### コミットメッセージ（Conventional Commits で統一）
`<type>: <要約>` 形式で書く。type は以下を用いる:

| type | 用途 |
|------|------|
| `feat` | 新機能 |
| `fix` | バグ修正 |
| `docs` | ドキュメントのみの変更 |
| `chore` | ビルド・設定・雑務など（プロダクトコード非変更） |
| `refactor` | 挙動を変えないリファクタリング |
| `test` | テストの追加・修正 |
| `perf` | パフォーマンス改善 |
| `style` | フォーマット等（挙動非変更） |

例:
```
feat: add per-app volume slider to menu bar
docs: deep-dive comparison of virtual-device vs process-tap
chore: set up develop branch and git conventions
```

## ドキュメント
- `docs/feasibility-study.md` — 基礎検討（技術フィージビリティ）
- `docs/approach-comparison.md` — 実現方式の詳細比較（方式A vs 方式B）
- `docs/app-store.md` — Mac App Store での配布とリリース手順
- `docs/release-flow.md` — リリースフロー（main マージで App Store Connect へ自動アップロード）
