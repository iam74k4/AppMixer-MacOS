import AppKit
import SwiftUI
import CoreAudio

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
        /// 出力先デバイスの UID（nil なら既定出力）。
        var outputDeviceUID: String?
        /// 自動ダッキングで絞られている最中か。
        var ducked: Bool = false
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

    // MARK: - 自動ダッキング
    @Published var duckingEnabled: Bool = false
    /// ダッキング時に絞る先（0.0...1.0）。
    @Published var duckLevel: Float = 0.2
    /// マイク使用も引き金にするか。
    @Published var duckOnMicrophone: Bool = true
    /// いま何によってダッキングされているか（表示用。未発動なら nil）。
    @Published var duckingReason: String?

    /// ルーティング先の選択肢。
    @Published var outputDevices: [AudioDevice] = []

    @Published var launchAtLogin: Bool = false
    /// 自動起動の切り替えに失敗した理由（成功時は nil）。
    @Published var launchAtLoginProblem: String?

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
    /// メーター用タップの生成に失敗した回数。上限を超えたら諦める。
    private var meteringFailures: [String: Int] = [:]
    private static let meteringRetryLimit = 2
    /// ダッキング判定用のタイマー（表示に関係なく動く）。
    private var duckTimer: Timer?

    private static let duckingEnabledKey = "appmixer.ducking.enabled"
    private static let duckLevelKey = "appmixer.ducking.level"
    private static let duckMicKey = "appmixer.ducking.microphone"

    init() {
        // F11/F12 やシステム設定でマスター音量が変わったら即座に表示へ反映する。
        // 値だけを読み直す軽い経路にする。対応可否やデバイス名の再取得まで
        // 走らせると、キーリピート中に HAL 呼び出しが大量に発生する。
        controller.onMasterChanged = { [weak self] in
            MainActor.assumeIsolated { guard let self else { return }; self.syncMasterValues() }
        }

        // 音声プロセスの増減に追従する。ポップオーバーを開いていなくても、
        // 再起動したアプリや新しい音声ヘルパーにタップを張り直す必要がある。
        controller.onProcessListChanged = { [weak self] in
            MainActor.assumeIsolated { guard let self else { return }; self.scheduleProcessResync() }
        }

        // 出力先が切り替わったら、そのデバイス用に覚えている音量へ入れ替える。
        controller.onDefaultDeviceChanged = { [weak self] in
            MainActor.assumeIsolated { guard let self else { return }; self.applyMemoryForCurrentDevice() }
        }

        // タップ中のアプリは .mutedWhenTapped で通常経路から外れているため、
        // 後始末をせずに終了するとそのアプリが無音のままになる。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.controller.shutdown() }
        }

        startIdleWatchdog()

        // 保存済みのダッキング設定を読み込む。
        duckingEnabled = defaults.bool(forKey: Self.duckingEnabledKey)
        if defaults.object(forKey: Self.duckLevelKey) != nil {
            duckLevel = defaults.float(forKey: Self.duckLevelKey)
        }
        if defaults.object(forKey: Self.duckMicKey) != nil {
            duckOnMicrophone = defaults.bool(forKey: Self.duckMicKey)
        }
        if duckingEnabled { startDuckTimer() }
    }

    deinit {
        idleWatchdog?.invalidate()
        duckTimer?.invalidate()
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
        // 解放中に開き直されたら中断する。
        controller.cancelMeteringRelease()
        meteringFailures.removeAll()
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
        // 常駐アプリなので、他のウェイクアップとまとめてもらう。
        timer.tolerance = 1.5
        RunLoop.main.add(timer, forMode: .common)
        idleWatchdog = timer
    }

    private func releaseMetersIfIdle() {
        guard let lastTick, Date().timeIntervalSince(lastTick) > 2.0 else { return }
        // 「閉じられた」のか「メインスレッドが詰まっていただけ」なのかを
        // ここでは区別できない。一拍おいて、それでも更新が来ていなければ解放する。
        // 詰まりで毎回壊すと、集約デバイスの生成破棄を繰り返して音飛びする。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self,
                  let lastTick = self.lastTick,
                  Date().timeIntervalSince(lastTick) > 2.0 else { return }
            self.lastTick = nil
            self.controller.releaseMeteringOnlyTaps()
        }
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
        refresh(with: AudioAppEnumerator.enumerate())
    }

    private func refresh(with enumerated: [AudioApp]) {
        // 反映に失敗している行の印は引き継ぐ（作り直すたびに消さない）。
        let previouslyFailed = Set(apps.filter(\.failed).map(\.id))

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
                metered: controller.hasFreshTap(for: app),
                failed: previouslyFailed.contains(app.id),
                outputDeviceUID: state.outputDeviceUID,
                ducked: duckingReason != nil && !DuckingDetector.isCommunicationApp(app)
            )
        }
        outputDevices = AudioDeviceEnumerator.outputDevices()

        refreshMaster()
        permission = AudioCapturePermission.current()
        refreshLaunchAtLogin()
    }

    // MARK: - デバイスごとの音量記憶

    /// 出力デバイスが切り替わったとき、そのデバイス用に覚えている音量へ入れ替える。
    ///
    /// 記憶が無いデバイスへ移った場合は、直前の音量をそのまま持ち込んで
    /// その場で記憶する。既定値（100%）に戻してしまうと、ヘッドフォンを挿した
    /// 瞬間に音量が跳ね上がることになるため。
    private func applyMemoryForCurrentDevice() {
        let enumerated = AudioAppEnumerator.enumerate()

        for app in enumerated {
            // 振り分け先を明示しているアプリは出力先が変わらないので対象外。
            guard controller.state(forID: app.id).outputDeviceUID == nil else { continue }

            let stored = storedSettings(for: app)
            guard let remembered = stored.perDevice[currentDefaultDeviceUID] else {
                // このデバイスの記憶が無い。いまの音量を引き継いで覚える。
                if controller.states[app.id] != nil { saveSetting(for: app) }
                continue
            }

            // 記憶があっても、鳴っていないアプリにタップは要らない。
            // ここで一斉にタップを張ると集約デバイスがまとめて作られ、
            // そのデバイスで再生中の音がすべて飛ぶ。鳴り始めた時点で
            // refresh() 側が復元するので、状態だけ入れておけばよい。
            guard app.isRunningOutput || controller.hasTap(forID: app.id) else {
                continue
            }

            controller.restore(
                MixerController.State(
                    volume: remembered.volume,
                    muted: remembered.muted,
                    outputDeviceUID: nil
                ),
                for: app
            )
        }

        refresh(with: enumerated)
    }

    /// この音量がどのデバイスに対して記憶されるか（表示用）。
    func memoryDeviceName(for app: AudioApp) -> String {
        if let routed = controller.state(forID: app.id).outputDeviceUID {
            return outputDeviceName(routed)
        }
        return outputName
    }

    // MARK: - 出力先ルーティング

    func setOutputDevice(_ uid: String?, for app: AudioApp) {
        var ok = controller.setOutputDevice(uid, for: app)

        // 振り分け先を変えると音の出るデバイスが変わる。そのデバイス用に
        // 覚えている音量があればそちらへ入れ替える（無ければ今の値を覚える）。
        let stored = storedSettings(for: app)
        let device = uid ?? currentDefaultDeviceUID
        if let remembered = stored.perDevice[device] {
            ok = controller.setVolume(remembered.volume, for: app) && ok
            ok = controller.setMuted(remembered.muted, for: app) && ok
        }
        saveSetting(for: app)

        let state = controller.state(forID: app.id)
        updateRow(app.id) {
            $0.outputDeviceUID = uid
            $0.volume = state.volume
            $0.muted = state.muted
            $0.metered = controller.hasFreshTap(for: app)
            $0.failed = !ok
        }
    }

    func outputDeviceName(_ uid: String?) -> String {
        guard let uid else { return "既定の出力" }
        return outputDevices.first { $0.uid == uid }?.name ?? "不明なデバイス"
    }

    // MARK: - 自動ダッキング

    func setDuckingEnabled(_ enabled: Bool) {
        duckingEnabled = enabled
        defaults.set(enabled, forKey: Self.duckingEnabledKey)
        if enabled { startDuckTimer() }
        evaluateDucking()
    }

    /// ダッキングはポップオーバーを閉じていても働く必要があるため、
    /// 表示用タイマーとは別に、有効な間だけ回す監視を持つ。
    private func startDuckTimer() {
        guard duckTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.evaluateDucking() }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        duckTimer = timer
    }

    func setDuckLevel(_ level: Float) {
        duckLevel = max(0.0, min(1.0, level))
        defaults.set(duckLevel, forKey: Self.duckLevelKey)
        // 発動中なら新しい深さを即座に反映する。
        if duckingReason != nil {
            applyDucking(active: true, apps: AudioAppEnumerator.enumerate())
        }
    }

    func setDuckOnMicrophone(_ enabled: Bool) {
        duckOnMicrophone = enabled
        defaults.set(enabled, forKey: Self.duckMicKey)
        evaluateDucking()
    }

    /// いま通話中かを判定し、状態が変わったらダッキングを適用/解除する。
    /// ポップオーバーを閉じていても動く必要があるため、
    /// 画面用の一覧ではなくその場で列挙した結果を使う。
    private func evaluateDucking() {
        guard duckingEnabled else {
            if duckingReason != nil {
                duckingReason = nil
                applyDucking(active: false, apps: AudioAppEnumerator.enumerate())
            }
            duckTimer?.invalidate()
            duckTimer = nil
            return
        }

        let all = AudioAppEnumerator.enumerate()
        let reason = DuckingDetector.evaluate(apps: all, useMicrophone: duckOnMicrophone)

        if reason != duckingReason {
            duckingReason = reason
            applyDucking(active: reason != nil, apps: all)
        } else if reason != nil {
            // 発動中に鳴り始めたアプリも絞る。
            controller.syncTaps(with: all)
        }
    }

    private func applyDucking(active: Bool, apps all: [AudioApp]) {
        // 通話アプリ自身は絞らない（絞ると相手の声が聞こえなくなる）。
        let excluded = Set(all.filter(DuckingDetector.isCommunicationApp).map(\.id))
        controller.setDucking(
            multiplier: active ? duckLevel : 1.0,
            excludedIDs: excluded,
            apps: all
        )
        for index in apps.indices {
            let isExcluded = excluded.contains(apps[index].id)
            apps[index].ducked = active && !isExcluded
            apps[index].metered = controller.hasFreshTap(for: apps[index].app)
        }
    }

    // MARK: - Launch at login

    func refreshLaunchAtLogin() {
        let state = LaunchAtLogin.state
        let enabled = (state == .enabled)
        if launchAtLogin != enabled { launchAtLogin = enabled }

        let problem: String?
        switch state {
        case .requiresApproval:
            problem = "システム設定のログイン項目で許可してください"
        case .notFound:
            problem = "アプリの場所が変わりました。一度オフにして入れ直してください"
        case .enabled, .disabled:
            problem = nil
        }
        if launchAtLoginProblem != problem { launchAtLoginProblem = problem }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        launchAtLoginProblem = LaunchAtLogin.setEnabled(enabled)
        // 実際に登録できたかは OS 側の状態で確認する。
        refreshLaunchAtLogin()
    }

    func openLoginItemsSettings() {
        LaunchAtLogin.openSettings()
    }

    /// メーターがまだ出ていない再生中のアプリを 1 つだけ拾ってタップを張る。
    private func attachNextMeteringTap() {
        // 権限状態では判定しない。TCC の状態取得は環境によって
        // .notDetermined のままになることがあり、そこで弾くと
        // 実際には許可されていてもメーターが永久に出なくなる。
        // 張れなければ activate() が失敗するだけなので、まず試す。
        // タップを張れないアプリ（システムプロセス等）で延々と再試行して
        // 後続のアプリにメーターが付かなくなるのを防ぐため、
        // 失敗が続いたものは対象から外す。
        // 見えている行だけを対象にする。検索で絞り込んでいるのに
        // 画面外のアプリぶんまで集約デバイスを作らない。
        let visible = Set(filteredApps.map(\.id))
        guard let index = apps.firstIndex(where: {
            visible.contains($0.id) && $0.app.isRunningOutput
                && !controller.hasFreshTap(for: $0.app)
                && (meteringFailures[$0.id] ?? 0) < Self.meteringRetryLimit
        }) else {
            return
        }
        let app = apps[index].app
        let ok = controller.ensureMeteringTap(for: app)
        if ok {
            meteringFailures[app.id] = nil
        } else {
            meteringFailures[app.id, default: 0] += 1
        }
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
        // 列挙は 1 回だけ。判定と作り直しで二重に走らせない。
        let enumerated = AudioAppEnumerator.enumerate()
        let current = apps.map { AppFingerprint($0.app) }
        let latest = enumerated.map { AppFingerprint($0) }
        guard current != latest else { return }
        refresh(with: enumerated)
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
            MainActor.assumeIsolated { guard let self else { return }; self.refresh() }
        }
        processResyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// マスター音量まわりを読み直す（対応可否やデバイス名も含む重い経路）。
    func refreshMaster() {
        // 変化したときだけ書き込む。毎回代入すると画面全体が再描画される。
        let supported = controller.masterVolumeSupported
        if masterSupported != supported { masterSupported = supported }
        let muteSupported = controller.masterMuteSupported
        if masterMuteSupported != muteSupported { masterMuteSupported = muteSupported }
        let name = controller.defaultOutputName()
        if outputName != name { outputName = name }
        syncMasterValues()
    }

    /// 音量とミュートの現在値だけを読み直す（ポーリング/通知用の軽い経路）。
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
        // 重い処理が同じフレームに重ならないよう位相をずらす。
        if meterTick % 3 == 1 { syncMasterValues() }

        // 表示中はアプリ一覧も定期的に見直す。プロセス一覧は「プロセスの
        // 生成/破棄」でしか変化しないため、起動済みのアプリが再生を
        // 始めただけでは通知が来ず、一覧に現れないままになる。
        if meterTick % 30 == 0 { refreshAppsIfChanged() }

        // 再生中でメーターの出ていないアプリに、順番にタップを張っていく。
        // 一度に一つだけにして、集約デバイスの一斉生成による音飛びを避ける。
        if meterTick % 15 == 7 { attachNextMeteringTap() }

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
        suppressMasterSyncUntil = Date().addingTimeInterval(0.45)
        if controller.setMasterVolume(volume) {
            masterVolume = volume
        } else {
            // 書き込めないデバイスもある。効いていない値を表示し続けない。
            suppressMasterSyncUntil = nil
            refreshMaster()
        }
    }

    func setMasterMuted(_ muted: Bool) {
        suppressMasterSyncUntil = Date().addingTimeInterval(0.45)
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

    // MARK: - Persistence
    //
    // 音量とミュートは「アプリ × 出力デバイス」で覚える。
    // ヘッドフォンとスピーカーでは適正音量が違うため、1 つしか覚えないと
    // 挿し替えるたびに調整し直しになる。
    // 出力先の振り分け（ルーティング）はデバイスに依存しないのでアプリ単位。

    /// あるデバイスでの音量設定。
    private struct DeviceVolume: Codable {
        var volume: Float
        var muted: Bool
    }

    /// アプリ 1 つぶんの保存内容。
    private struct StoredSettings: Codable {
        /// 振り分け先（nil なら既定出力に追従）。
        var outputDeviceUID: String?
        /// 出力デバイス UID -> 音量設定。
        var perDevice: [String: DeviceVolume] = [:]
    }

    /// 旧形式（デバイスを区別しなかった頃）の保存内容。読み込み時の移行にだけ使う。
    private struct LegacySetting: Codable {
        var volume: Float
        var muted: Bool
        var outputDeviceUID: String?
    }

    private func storageKey(for app: AudioApp) -> String? {
        app.bundleID.map { "appmixer.setting.\($0)" }
    }

    /// いまそのアプリの音が出ているデバイスの UID。
    /// 振り分けていればその先、していなければ既定出力。
    private func deviceKey(for app: AudioApp) -> String {
        if let routed = controller.state(forID: app.id).outputDeviceUID { return routed }
        return currentDefaultDeviceUID
    }

    private var currentDefaultDeviceUID: String {
        CoreAudioObject.deviceUID(CoreAudioObject.defaultOutputDeviceID()) ?? "default"
    }

    private func storedSettings(for app: AudioApp) -> StoredSettings {
        guard let key = storageKey(for: app), let data = defaults.data(forKey: key) else {
            return StoredSettings()
        }
        if let stored = try? JSONDecoder().decode(StoredSettings.self, from: data) {
            return stored
        }
        // 旧形式は、そのときの既定デバイスの設定だったものとして引き継ぐ。
        if let legacy = try? JSONDecoder().decode(LegacySetting.self, from: data) {
            var migrated = StoredSettings(outputDeviceUID: legacy.outputDeviceUID)
            let device = legacy.outputDeviceUID ?? currentDefaultDeviceUID
            migrated.perDevice[device] = DeviceVolume(volume: legacy.volume, muted: legacy.muted)
            return migrated
        }
        return StoredSettings()
    }

    private func saveSetting(for app: AudioApp) {
        guard let key = storageKey(for: app) else { return }
        let state = controller.state(forID: app.id)
        var stored = storedSettings(for: app)
        stored.outputDeviceUID = state.outputDeviceUID
        stored.perDevice[deviceKey(for: app)] = DeviceVolume(
            volume: state.volume, muted: state.muted
        )
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }

    private func loadSetting(for app: AudioApp) -> MixerController.State? {
        guard storageKey(for: app) != nil else { return nil }
        let stored = storedSettings(for: app)
        // 振り分け先が決まっているなら、その先のデバイスの音量を読む。
        let device = stored.outputDeviceUID ?? currentDefaultDeviceUID
        guard let saved = stored.perDevice[device] else {
            // このデバイスの記憶が無い場合、振り分けだけ復元して音量は既定にする。
            guard stored.outputDeviceUID != nil else { return nil }
            return MixerController.State(outputDeviceUID: stored.outputDeviceUID)
        }
        return MixerController.State(
            volume: saved.volume, muted: saved.muted, outputDeviceUID: stored.outputDeviceUID
        )
    }

    private func updateRow(_ id: String, _ mutate: (inout DisplayApp) -> Void) {
        if let index = apps.firstIndex(where: { $0.id == id }) {
            mutate(&apps[index])
        }
    }
}
