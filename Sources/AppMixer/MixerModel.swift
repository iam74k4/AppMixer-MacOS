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
        /// 音量を反映できなかった（タップを張れていない）。表示と実際の音が食い違う。
        var failed: Bool = false
        var id: String { app.id }
    }

    @Published var apps: [DisplayApp] = []
    @Published var searchText: String = ""
    @Published var showAllApps: Bool = false

    @Published var masterVolume: Float = 1.0
    @Published var masterMuted: Bool = false
    @Published var masterSupported: Bool = true
    @Published var masterMuteSupported: Bool = true
    @Published var outputName: String = ""

    @Published var permission: AudioCapturePermission.Status = .notDetermined

    private let controller = MixerController()
    private let defaults = UserDefaults.standard
    private var meterTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    /// 自分の書き込みによるリスナー反射を無視する期限。
    private var suppressMasterSyncUntil: Date?
    /// プロセス一覧はまとまって変化するため、少し待ってから一度だけ同期する。
    private var processResyncWorkItem: DispatchWorkItem?

    init() {
        // F11/F12 やシステム設定でマスター音量が変わったら即座に表示へ反映する。
        controller.onMasterChanged = { [weak self] in
            MainActor.assumeIsolated { self?.refreshMaster() }
        }

        // 音声プロセスの増減に追従する。ポップオーバーを開いていなくても、
        // 再起動したアプリや新しい音声ヘルパーにタップを張り直す必要がある。
        controller.onProcessListChanged = { [weak self] in
            MainActor.assumeIsolated { self?.scheduleProcessResync() }
        }

        // タップ中のアプリは .mutedWhenTapped で通常経路から外れているため、
        // 後始末をせずに終了するとそのアプリが無音のままになる。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.shutdown() }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

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

        // 新規アプリは永続化した設定を復元する。
        // 再生中のものだけに絞る。停止中のアプリまで一斉にタップを張ると、
        // 集約デバイスの生成が連続してそのデバイス上の全再生が音飛びする。
        // 停止中のアプリは、再生を始めた時点でプロセス一覧の変化を拾って復元される。
        for app in enumerated where controller.states[app.id] == nil && app.isRunningOutput {
            if let saved = loadSetting(for: app) {
                controller.restore(saved, for: app)
            }
        }
        controller.prune(aliveIDs: Set(enumerated.map(\.id)))
        // 音声ヘルパーが入れ替わったアプリのタップを張り直す
        controller.syncTaps(with: enumerated)

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

        refreshMaster()
        permission = AudioCapturePermission.current()
    }

    /// プロセス一覧の変化をまとめて処理する（連続通知を 1 回に束ねる）。
    private func scheduleProcessResync() {
        processResyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        processResyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// マスター音量まわりだけを読み直す（外部変更の反映用）。
    func refreshMaster() {
        masterSupported = controller.masterVolumeSupported
        masterMuteSupported = controller.masterMuteSupported
        outputName = controller.defaultOutputName()

        // 自分で書いた直後は、その反射を無視して操作中の値を保つ。
        if let until = suppressMasterSyncUntil, Date() < until { return }
        suppressMasterSyncUntil = nil
        masterVolume = controller.masterVolume()
        masterMuted = controller.masterMuted()
    }

    private func tickMeters() {
        guard !apps.isEmpty else { return }
        // 変化があったときだけ書き込む。毎フレーム代入すると、全アプリが
        // 無音でも 30fps で画面全体の再描画を起こしてしまう。
        for index in apps.indices {
            let id = apps[index].id
            let level = controller.level(forID: id)
            let metered = controller.hasTap(forID: id)
            if apps[index].level != level { apps[index].level = level }
            if apps[index].metered != metered { apps[index].metered = metered }
        }
    }

    // MARK: - Per-app control

    func setVolume(_ volume: Float, for app: AudioApp) {
        let ok = controller.setVolume(volume, for: app)
        saveSetting(for: app)
        updateRow(app.id) {
            $0.volume = volume
            $0.metered = controller.hasTap(forID: app.id)
            $0.failed = !ok
        }
    }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        let ok = controller.setMuted(muted, for: app)
        saveSetting(for: app)
        updateRow(app.id) {
            $0.muted = muted
            $0.metered = controller.hasTap(forID: app.id)
            $0.failed = !ok
        }
    }

    // MARK: - Master

    func setMasterVolume(_ volume: Float) {
        // 自分の書き込みもリスナーを起こすため、その反射でスライダーが
        // 操作中に跳ねないよう、直後の短い間だけ外部反映を抑制する。
        suppressMasterSyncUntil = Date().addingTimeInterval(0.15)
        if controller.setMasterVolume(volume) {
            masterVolume = volume
        } else {
            // 書き込めないデバイスもある。効いていない値を表示し続けない。
            suppressMasterSyncUntil = nil
            refreshMaster()
        }
    }

    func setMasterMuted(_ muted: Bool) {
        suppressMasterSyncUntil = Date().addingTimeInterval(0.15)
        if controller.setMasterMuted(muted) {
            masterMuted = muted
        } else {
            suppressMasterSyncUntil = nil
            refreshMaster()
        }
    }

    // MARK: - Permission / app control

    func requestPermission() {
        AudioCapturePermission.request { [weak self] granted in
            guard let self else { return }
            // 拒否と決めつけない。まだ聞かれていないだけの場合がある。
            self.permission = granted ? .authorized : AudioCapturePermission.current()
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
        // 終了通知が届く前に確実にタップを解除し、各アプリの音声を戻す。
        controller.shutdown()
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
