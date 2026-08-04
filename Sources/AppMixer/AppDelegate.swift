import AppKit
import CoreAudio

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private let menu = NSMenu()

    // 14.2+ でのみ有効な実体。
    private var mixerStorage: AnyObject?
    @available(macOS 14.2, *)
    private var mixer: MixerController {
        if let m = mixerStorage as? MixerController { return m }
        let m = MixerController()
        mixerStorage = m
        return m
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "slider.vertical.3", accessibilityDescription: "AppMixer"
        )
        menu.delegate = self
        statusItem.menu = menu

        // 起動時に権限状態を確認し、未決定なら要求（プロンプト表示）。
        if #available(macOS 14.2, *) {
            if AudioCapturePermission.current() == .notDetermined {
                AudioCapturePermission.request { _ in }
            }
        }
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        guard #available(macOS 14.2, *) else {
            let item = NSMenuItem(title: "macOS 14.4 以降が必要です", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            addQuitItem()
            return
        }

        // 権限チェック
        switch AudioCapturePermission.current() {
        case .denied:
            addDisabled("システム音声録音の許可が必要です")
            addActionItem("システム設定を開く…", #selector(openPrivacySettings))
            menu.addItem(.separator())
        case .notDetermined:
            addDisabled("許可を確認しています…")
            addActionItem("許可をリクエスト", #selector(requestPermission))
            menu.addItem(.separator())
        case .authorized:
            break
        }

        // 出力デバイス見出し
        let outputID = CoreAudioObject.defaultOutputDeviceID()
        let deviceName = CoreAudioObject.deviceName(outputID) ?? "不明な出力デバイス"
        addDisabled("出力先: \(deviceName)")
        menu.addItem(.separator())

        // 音を出しているアプリ一覧
        let processes = AudioProcessController.runningOutputProcesses()
        mixer.pruneTerminatedProcesses(alive: Set(processes.map(\.pid)))

        if processes.isEmpty {
            addDisabled("再生中のアプリはありません")
        } else {
            for process in processes {
                let itemView = AppVolumeItemView(process: process, mixer: mixer)
                let item = NSMenuItem()
                item.view = itemView
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        addQuitItem()
    }

    // MARK: - Menu helpers

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func addActionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addQuitItem() {
        addActionItem("AppMixer を終了", #selector(quit)).keyEquivalent = "q"
    }

    // MARK: - Actions

    @objc private func requestPermission() {
        if #available(macOS 14.2, *) {
            AudioCapturePermission.request { _ in }
        }
    }

    @objc private func openPrivacySettings() {
        // Privacy & Security → System Audio Recording
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
