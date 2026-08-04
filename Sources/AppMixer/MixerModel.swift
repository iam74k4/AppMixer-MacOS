import AppKit
import SwiftUI

// SwiftUI とオーディオエンジン(MixerController)を仲介する ObservableObject。
// アプリ一覧・マスター音量・検索・権限・メーターを @Published で公開する。

@MainActor
final class MixerModel: ObservableObject {

    struct DisplayApp: Identifiable {
        let app: AudioApp
        let icon: NSImage?
        var volume: Float
        var muted: Bool
        var level: Float
        /// タップが張られている（＝レベルを計測できる）場合のみメーターを表示する。
        var metered: Bool
        var id: String { app.id }
    }

    @Published var apps: [DisplayApp] = []
    @Published var searchText: String = ""
    @Published var showAllApps: Bool = false

    @Published var masterVolume: Float = 1.0
    @Published var masterMuted: Bool = false
    @Published var masterSupported: Bool = true
    @Published var outputName: String = ""

    @Published var permission: AudioCapturePermission.Status = .notDetermined

    private let controller = MixerController()
    private let defaults = UserDefaults.standard
    private var meterTimer: Timer?

    // MARK: - Derived

    var filteredApps: [DisplayApp] {
        apps.filter { display in
            let visible = showAllApps || display.app.isRunningOutput
            let matches = searchText.isEmpty
                || display.app.name.localizedCaseInsensitiveContains(searchText)
            return visible && matches
        }
    }

    // MARK: - Lifecycle (popover open/close)

    func onAppear() {
        refresh()
        meterTimer?.invalidate()
        // .common モードで登録する。既定の .default だけだと、スライダー操作中
        // （ランループが .eventTracking になる）にメーターが止まってしまう。
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickMeters() }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    func onDisappear() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    // MARK: - Refresh

    func refresh() {
        let enumerated = AudioAppEnumerator.enumerate()

        // 新規アプリは永続化した設定を復元
        for app in enumerated where controller.states[app.id] == nil {
            if let saved = loadSetting(for: app) {
                controller.restore(saved, for: app)
            }
        }
        controller.prune(aliveIDs: Set(enumerated.map(\.id)))

        apps = enumerated.map { app in
            let state = controller.state(forID: app.id)
            return DisplayApp(
                app: app,
                icon: app.icon,
                volume: state.volume,
                muted: state.muted,
                level: controller.level(forID: app.id),
                metered: controller.hasTap(forID: app.id)
            )
        }

        masterSupported = controller.masterVolumeSupported
        masterVolume = controller.masterVolume()
        masterMuted = controller.masterMuted()
        outputName = controller.defaultOutputName()
        permission = AudioCapturePermission.current()
    }

    private func tickMeters() {
        guard !apps.isEmpty else { return }
        for index in apps.indices {
            let id = apps[index].id
            apps[index].level = controller.level(forID: id)
            apps[index].metered = controller.hasTap(forID: id)
        }
    }

    // MARK: - Per-app control

    func setVolume(_ volume: Float, for app: AudioApp) {
        controller.setVolume(volume, for: app)
        saveSetting(for: app)
        updateRow(app.id) {
            $0.volume = volume
            $0.metered = controller.hasTap(forID: app.id)
        }
    }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        controller.setMuted(muted, for: app)
        saveSetting(for: app)
        updateRow(app.id) {
            $0.muted = muted
            $0.metered = controller.hasTap(forID: app.id)
        }
    }

    // MARK: - Master

    func setMasterVolume(_ volume: Float) {
        controller.setMasterVolume(volume)
        masterVolume = volume
    }

    func setMasterMuted(_ muted: Bool) {
        controller.setMasterMuted(muted)
        masterMuted = muted
    }

    // MARK: - Permission / app control

    func requestPermission() {
        AudioCapturePermission.request { [weak self] granted in
            guard let self else { return }
            self.permission = granted ? .authorized : .denied
            self.refresh()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Persistence (UserDefaults, keyed by bundleID)

    private struct Setting: Codable {
        var volume: Float
        var muted: Bool
    }

    private func storageKey(for app: AudioApp) -> String? {
        app.bundleID.map { "appmixer.setting.\($0)" }
    }

    private func saveSetting(for app: AudioApp) {
        guard let key = storageKey(for: app) else { return }
        let state = controller.state(forID: app.id)
        let setting = Setting(volume: state.volume, muted: state.muted)
        if let data = try? JSONEncoder().encode(setting) {
            defaults.set(data, forKey: key)
        }
    }

    private func loadSetting(for app: AudioApp) -> MixerController.State? {
        guard let key = storageKey(for: app),
              let data = defaults.data(forKey: key),
              let setting = try? JSONDecoder().decode(Setting.self, from: data) else {
            return nil
        }
        return MixerController.State(volume: setting.volume, muted: setting.muted)
    }

    private func updateRow(_ id: String, _ mutate: (inout DisplayApp) -> Void) {
        if let index = apps.firstIndex(where: { $0.id == id }) {
            mutate(&apps[index])
        }
    }
}
