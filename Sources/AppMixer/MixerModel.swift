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
    private var terminationObserver: NSObjectProtocol?
    /// 自分の書き込みによるリスナー反射を無視する期限。
    private var suppressMasterSyncUntil: Date?
    /// プロセス一覧はまとまって変化するため、少し待ってから一度だけ同期する。
    private var processResyncWorkItem: DispatchWorkItem?
    /// マスター音量のポーリング頻度を落とすためのカウンタ。
    private var meterTick: UInt64 = 0
    /// 最後に表示更新が来た時刻（閉じられたことの検知に使う）。
    private var lastTick: Date?
    private var idleWatchdog: Timer?

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

        startIdleWatchdog()
    }

    deinit {
        idleWatchdog?.invalidate()
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
    }

    /// 表示中に一定間隔で呼ばれる（駆動はビュー側のタイマー）。
    func tick() {
        lastTick = Date()
        tickMeters()
    }

    /// 表示が終わったのに onDisappear が来ないことがあるため、
    /// tick が途絶えたら（＝閉じられたら）メーター用タップを解放する。
    private func startIdleWatchdog() {
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.releaseMetersIfIdle() }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleWatchdog = timer
    }

    private func releaseMetersIfIdle() {
        guard let lastTick, Date().timeIntervalSince(lastTick) > 2.0 else { return }
        self.lastTick = nil
        controller.releaseMeteringOnlyTaps()
    }

    func onDisappear() {
        // 表示していない間は、メーター用に張っただけのタップを解放する。
        // 音量を変えたアプリのタップはそのまま維持する。
        controller.releaseMeteringOnlyTaps()
        for index in apps.indices {
            apps[index].metered = controller.hasTap(forID: apps[index].id)
        }
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

    /// メーターがまだ出ていない再生中のアプリを 1 つだけ拾ってタップを張る。
    private func attachNextMeteringTap() {
        // 権限状態では判定しない。TCC の状態取得は環境によって
        // .notDetermined のままになることがあり、そこで弾くと
        // 実際には許可されていてもメーターが永久に出なくなる。
        // 張れなければ activate() が失敗するだけなので、まず試す。
        guard let index = apps.firstIndex(where: { $0.app.isRunningOutput && !$0.metered }) else {
            return
        }
        let app = apps[index].app
        let ok = controller.ensureMeteringTap(for: app)
        apps[index].metered = controller.hasTap(forID: app.id)
        // 失敗しても音量設定そのものが効いていないとは限らないので、
        // 既に失敗表示が無い行にだけ印を付ける。
        if !ok && !apps[index].failed && apps[index].volume < 0.999 {
            apps[index].failed = true
        }
    }

    /// 一覧の顔ぶれや再生状態が変わったときだけ作り直す。
    /// 毎秒まるごと差し替えると、操作中のスライダーが揺れてしまう。
    private func refreshAppsIfChanged() {
        let enumerated = AudioAppEnumerator.enumerate()
        let current = apps.map { AppFingerprint($0.app) }
        let latest = enumerated.map { AppFingerprint($0) }
        guard current != latest else { return }
        refresh()
    }

    /// 一覧を作り直すべきかの判定に使う指紋。
    private struct AppFingerprint: Equatable {
        let id: String
        let running: Bool
        let processObjectIDs: Set<AudioObjectID>

        init(_ app: AudioApp) {
            id = app.id
            running = app.isRunningOutput
            processObjectIDs = Set(app.processObjectIDs)
        }
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

    /// マスター音量まわりを読み直す（対応可否やデバイス名も含む）。
    func refreshMaster() {
        masterSupported = controller.masterVolumeSupported
        masterMuteSupported = controller.masterMuteSupported
        outputName = controller.defaultOutputName()
        syncMasterValues()
    }

    /// 音量とミュートの現在値だけを読み直す（ポーリング用の軽い経路）。
    private func syncMasterValues() {
        // 自分で書いた直後は、その反射を無視して操作中の値を保つ。
        if let until = suppressMasterSyncUntil {
            if Date() < until { return }
            suppressMasterSyncUntil = nil
        }
        let volume = controller.masterVolume()
        let muted = controller.masterMuted()
        // 変化したときだけ書き込み、無駄な再描画を避ける。
        if masterVolume != volume { masterVolume = volume }
        if masterMuted != muted { masterMuted = muted }
    }

    private func tickMeters() {
        // 表示中は自前で読みに行く。デバイスによってはプロパティ通知が
        // 届かないことがあり、リスナーだけだと F11/F12 に追従できない。
        meterTick &+= 1
        if meterTick % 3 == 0 { syncMasterValues() }

        // 表示中はアプリ一覧も定期的に見直す。プロセス一覧は「プロセスの
        // 生成/破棄」でしか変化しないため、起動済みのアプリが再生を
        // 始めただけでは通知が来ず、一覧に現れないままになる。
        if meterTick % 30 == 0 { refreshAppsIfChanged() }

        // 再生中でメーターの出ていないアプリに、順番にタップを張っていく。
        // 一度に一つだけにして、集約デバイスの一斉生成による音飛びを避ける。
        if meterTick % 15 == 0 { attachNextMeteringTap() }

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
