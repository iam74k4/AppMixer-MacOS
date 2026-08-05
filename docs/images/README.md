# 画像

README で使う UI レイアウト図。**スクリーンショットではなく、実装のレイアウト定義から
起こした図**です（実機のビルドが手元に無い環境でも更新できるようにするため）。

| ファイル | 用途 |
|---|---|
| `mixer-light.svg` | ライトモード |
| `mixer-dark.svg` | ダークモード |
| `make_mockup.py` | 上記 2 つを生成 |
| `outline_text.py` | SVG 内の文字をパス化（閲覧側に日本語フォントが無くても崩れないように） |

## 更新のしかた

`ContentView` / `AppRowView` のレイアウトを変えたら、`make_mockup.py` の座標も合わせて
更新してから再生成してください。

```bash
cd docs/images
python3 make_mockup.py
python3 outline_text.py mixer-light.svg mixer-dark.svg
```

`outline_text.py` には日本語フォント（Noto Sans CJK）と `fonttools` が必要です。

実機のスクリーンショットが用意できるなら、そちらへ差し替えるのが最善です。
