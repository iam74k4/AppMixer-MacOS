import AppKit

// メニューバー常駐アプリのエントリポイント。
// Dock アイコンは出さない（Info.plist の LSUIElement + activationPolicy .accessory）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
