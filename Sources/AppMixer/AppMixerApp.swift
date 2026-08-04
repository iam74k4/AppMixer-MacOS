import SwiftUI

// メニューバー常駐アプリのエントリポイント。
// MenuBarExtra(.window) により、アイコンクリックで SwiftUI のポップオーバーを表示する。
// Dock アイコンは出さない（Info.plist の LSUIElement = true）。

@main
struct AppMixerApp: App {

    @StateObject private var model = MixerModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView(model: model)
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
