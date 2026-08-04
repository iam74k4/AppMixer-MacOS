import SwiftUI

// メニューバー常駐アプリのエントリポイント。
// MenuBarExtra(.window) により、アイコンクリックで SwiftUI のポップオーバーを表示する。
// Dock アイコンは出さない（Info.plist の LSUIElement = true）。

/// アプリ全体で 1 つだけ持つモデル。
///
/// App 側で @StateObject として持つと、モデルが更新されるたびに
/// シーンの body が再評価されてビューが作り直される。メーターは
/// 毎フレーム更新されるため、その影響が大きい。
/// ここで保持してシーンからは監視しない。
@MainActor
enum Mixer {
    static let shared = MixerModel()
}

@main
struct AppMixerApp: App {

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: Mixer.shared)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
