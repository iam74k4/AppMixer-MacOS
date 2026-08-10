import AppKit
import SwiftUI
import CoreAudio
import os

// SwiftUI とオーディオエンジン(MixerController)を仲介する ObservableObject。
// アプリ一覧・マスター音量・検索・権限・メーターを @Published で公開する。

@MainActor
final class MixerModel: ObservableObject {

    /// 表示と実際の音が食い違っている理由。
    enum Trouble: Equatable {
        /// 設定を反映できなかった（タップを張れていない）。音は元のまま鳴っている。
        case notApplied
        /// 出力先の切り替えに追従できず、いま音が出ていない。
        case silenced

        var message: String {
            switch self {
            case .notApplied:
                return "設定を適用できませんでした。実際の音は変わっていません。"
            case .silenced:
                return "出力先の切り替えに追従できず、このアプリの音が止まっています。復旧を試みています。"
            }
        }
    }

    struct DisplayApp: Identifiable {
        let app: AudioApp
        let icon: NSImage?
        var volume: Float
        var muted: Bool
        var level: Float
        /// タップが張られている（＝レベルを計測できる）場合のみメーターを表示する。
        var metered: Bool
        /// 不調があればその理由（正常なら nil）。
        var trouble: Trouble?
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
    /// いまの既定出力デバイスの UID（メニューのチェック判定に使う）。
    @Published var currentOutputUID: String?

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
    /// デバイス構成も同様。機器の抜き差し 1 回で通知は何度も飛ぶ。
    private var deviceResyncWorkItem: DispatchWorkItem?
    /// マスター音量のポーリング頻度を落とすためのカウンタ。
    private var meterTick: UInt64 = 0
    /// 最後に表示更新が来た時刻（閉じられたことの検知に使う）。
    private var lastTick: Date?
    /// ポップオーバーが表示されているとみなせるか。
    /// tick が続いている（または onAppear 直後の）間だけ true。閉じられた
    /// ことは onDisappear か idleWatchdog が lastTick を nil に戻して伝える。
    private var isPopoverShowing: Bool { lastTick != nil }
    /// アプリ id -> 取得済みアイコンと、取得時の本体アプリ pid。一覧を
    /// 作り直すたびに NSRunningApplication / NSWorkspace を引き直さない
    /// ための持ち越し。pid は世代の見分けに使う。同じ id でも再起動を
    /// 挟むと別のバイナリ（更新後のアイコン）でありうる。
    private var iconCache: [String: (pid: pid_t?, icon: NSImage)] = [:]
    private var idleWatchdog: Timer?
    /// メーター用タップの生成に失敗した回数。上限を超えたら諦める。
    private var meteringFailures: [String: Int] = [:]
    private static let meteringRetryLimit = 2
    /// ダッキング判定用のタイマー（表示に関係なく動く）。
    private var duckTimer: Timer?
    /// ダッキング判定で最後に引いたアプリ一覧と、その時点の通話アプリの
    /// id 集合。「下げる音量」を動かしたときの適用に使い回す。ドラッグ中に
    /// 列挙と除外集合の組み立てを繰り返さないためのもので、発動中は
    /// 1 秒以内に更新されている。
    private var lastEnumeratedApps: [AudioApp] = []
    private var lastExcludedIDs: Set<String> = []
    /// 保存待ちのアプリ設定。スライダーのドラッグ中は値が変わるたびに
    /// setVolume が呼ばれるため、その場で保存すると JSON の復号・符号化と
    /// UserDefaults への書き込みがイベントレートで走る。音への反映は即座に
    /// 行い、保存だけ手が止まるのを待って 1 回にする。
    private var pendingSaves: [String: (app: AudioApp, work: DispatchWorkItem)] = [:]
    /// 「下げる音量」の保存の予約。理由は pendingSaves と同じ。
    private var duckLevelSaveWork: DispatchWorkItem?

    private static let duckingEnabledKey = "appmixer.ducking.enabled"
    private static let duckLevelKey = "appmixer.ducking.level"
    private static let duckMicKey = "appmixer.ducking.microphone"
    private static let requestedPermissionKey = "appmixer.permission.requested"

    /// 一度でも許可を求めたか。求める前に勝手にダイアログを出さないための印。
    private var hasRequestedPermission: Bool {
        get { defaults.bool(forKey: Self.requestedPermissionKey) }
        set { defaults.set(newValue, forKey: Self.requestedPermissionKey) }
    }

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

        // 振り分け先のデバイスが抜かれたら既定出力へ戻す。
        // 放置するとそのアプリは音の出口を失って無音のままになる。
        controller.onDeviceListChanged = { [weak self] in
            MainActor.assumeIsolated { guard let self else { return }; self.scheduleDeviceResync() }
        }

        // タップの張り替えに失敗した／復旧した。黙って無音にせず画面に出す。
        controller.onTapTroubleChanged = { [weak self] in
            MainActor.assumeIsolated { guard let self else { return }; self.syncTapTrouble() }
        }

        // タップ中のアプリは .mutedWhenTapped で通常経路から外れているため、
        // 後始末をせずに終了するとそのアプリが無音のままになる。
        // 保存待ちの設定もここで書き切る。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flushPendingSaves()
                self.controller.shutdown()
            }
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
        // 最初の tick を待たずに「表示中」にする。これから呼ぶ refresh が
        // 表示中にしか行わない読み直し（権限・自動起動・デバイス一覧）を
        // この印で判定するため、先に立てておかないと開いた直後の一回が抜ける。
        lastTick = Date()
        refresh()
    }

    /// 表示中に一定間隔で呼ばれる（駆動はビュー側のタイマー）。
    func tick() {
        // onAppear が来ないまま再表示されることがある（ContentView 冒頭の
        // コメント参照）。閉じの検知を idleWatchdog が担っているのと対で、
        // 開きの検知はここが担う: tick が途絶えたあとの最初の tick を
        // 開き直しとみなし、onAppear と同じ読み直しを通す。これが無いと、
        // 閉じている間に変わったデバイス名やメニューが古いまま表示され続ける。
        let reopened = lastTick == nil
        lastTick = Date()
        if reopened { refresh() }
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
        // 来ないことがある通知だが、来たなら閉じたと確定している。
        // idleWatchdog の 2 秒を待たずに「表示中」を下ろす。
        lastTick = nil
        // 表示していない間は、メーター用に張っただけのタップを解放する。
        // 音量を変えたアプリのタップはそのまま維持する。
        controller.releaseMeteringOnlyTaps()
        for index in apps.indices {
            apps[index].metered = controller.hasFreshTap(for: apps[index].app)
        }
    }

    // MARK: - Refresh

    func refresh() {
        refresh(with: AudioAppEnumerator.enumerate())
    }

    private func refresh(with enumerated: [AudioApp]) {
        // 反映に失敗している行の印は引き継ぐ（作り直すたびに消さない）。
        let previouslyFailed = Set(apps.filter { $0.trouble == .notApplied }.map(\.id))

        // 新規アプリは永続化した設定を復元する。
        //
        // タップを張るのは再生中のものだけに絞る。停止中のアプリまで一斉に
        // 張ると、集約デバイスの生成が連続してそのデバイス上の全再生が音飛びする。
        // 停止中のアプリには状態だけ入れておき、鳴り始めた時点で反映する。
        //
        // 状態を入れずに飛ばすと、一覧が既定値（100%・ミュート解除）を表示して
        // しまう。ミュートしたはずのアプリが「100%」と出るうえ、行の操作まで
        // 既定値扱いで隠れる。実際に鳴らすと保存値で鳴るので、表示だけが嘘になる。
        for app in enumerated where controller.states[app.id] == nil {
            guard let saved = loadSetting(for: app) else { continue }
            if app.isRunningOutput {
                controller.restore(saved, for: app)
            } else {
                controller.seed(saved, for: app)
            }
        }
        let aliveIDs = Set(enumerated.map(\.id))
        controller.prune(aliveIDs: aliveIDs)
        iconCache = iconCache.filter { aliveIDs.contains($0.key) }
        // 音声ヘルパーが入れ替わったアプリのタップを張り直す
        controller.syncTaps(with: enumerated)

        // 失敗の印を引き継ぐのは「まだ反映できていない」行だけにする。設定どおりの
        // タップが張れた行や、設定が既定に戻ってそもそも反映するものが無い行から
        // 外さないと、復旧しても手でスライダーを動かすまで警告が残り続ける。
        // 判定はタップを張り直したあとの状態で行う必要があるため、ここで求める。
        let stillNotApplied = Set(
            enumerated.filter { app in
                previouslyFailed.contains(app.id)
                    && controller.state(forID: app.id).isCustomized
                    && !controller.hasFreshTap(for: app)
            }.map(\.id)
        )

        apps = enumerated.map { app in
            let state = controller.state(forID: app.id)
            return DisplayApp(
                app: app,
                icon: cachedIcon(for: app),
                volume: state.volume,
                muted: state.muted,
                level: controller.level(forID: app.id),
                metered: controller.hasFreshTap(for: app),
                // 無音になっている方が重い。こちらを優先して見せる。
                trouble: controller.isSilencedByFailedRebuild(id: app.id) ? .silenced
                    : (stillNotApplied.contains(app.id) ? .notApplied : nil),
                outputDeviceUID: state.outputDeviceUID,
                ducked: duckingReason != nil && app.isRunningOutput
                    && !DuckingDetector.isCommunicationApp(app)
            )
        }
        // ここから下は表示のためだけの読み直しで、閉じている間は誰も見ない。
        // refresh はプロセス一覧が変わるたび（ブラウザのタブ操作でも）呼ばれる
        // ため、閉じている間まで TCC への問い合わせ、servicemanagementd への
        // XPC、デバイス列挙を繰り返さない。表示は開いたときに追いつく:
        // onAppear が refresh を呼び、onAppear が来なかった開き直しでは
        // tick() が最初の 1 回で refresh を呼ぶ。
        guard isPopoverShowing else { return }
        outputDevices = AudioDeviceEnumerator.outputDevices()

        refreshMaster()
        permission = AudioCapturePermission.current()
        refreshLaunchAtLogin()
    }

    /// アイコンを取り出す（無ければ取得して覚える）。
    ///
    /// AudioApp.icon は NSRunningApplication か NSWorkspace を引く。一覧は
    /// プロセスの増減のたびに作り直されるため、毎回引き直すと常駐中ずっと
    /// その繰り返しになる。アイコンは同じ世代（同じ本体 pid）の間は変わら
    /// ないものとして持ち越す。消えたアプリのぶんは refresh が捨てるが、
    /// 一覧から消えたことを観測できない速さで再起動された場合も、pid の
    /// 変化で引き直されるため、更新後のアプリに古い絵を出し続けない。
    /// 取れなかったアプリは覚えず、次の作り直しでまた試す。
    private func cachedIcon(for app: AudioApp) -> NSImage? {
        if let cached = iconCache[app.id], cached.pid == app.iconAppPID {
            return cached.icon
        }
        guard let icon = app.icon else { return nil }
        iconCache[app.id] = (app.iconAppPID, icon)
        return icon
    }

    // MARK: - デバイスごとの音量記憶

    /// 出力デバイスが切り替わったとき、そのデバイス用に覚えている音量へ入れ替える。
    ///
    /// 記憶が無いデバイスへ移った場合は、直前の音量をそのまま持ち込んで
    /// その場で記憶する。既定値（100%）に戻してしまうと、ヘッドフォンを挿した
    /// 瞬間に音量が跳ね上がることになるため。
    private func applyMemoryForCurrentDevice() {
        // UID が読めないうちは記憶を入れ替えない。誤ったキーで読み書きすると
        // 別デバイスの設定を上書きしてしまう。
        guard let deviceUID = currentDefaultDeviceUID else { return }
        let enumerated = AudioAppEnumerator.enumerate()

        for app in enumerated {
            // 振り分け先を明示しているアプリは出力先が変わらないので対象外。
            guard controller.state(forID: app.id).outputDeviceUID == nil else { continue }

            let stored = storedSettings(for: app)
            guard let remembered = stored.perDevice[deviceUID] else {
                // このデバイスの記憶が無い。いまの音量を引き継いで覚える。
                if controller.states[app.id] != nil { saveSetting(for: app) }
                continue
            }

            let state = MixerController.State(
                volume: remembered.volume,
                muted: remembered.muted,
                outputDeviceUID: nil
            )

            // 鳴っていないアプリにタップは要らない。ここで一斉に張ると
            // 集約デバイスがまとめて作られ、そのデバイスで再生中の音が
            // すべて飛ぶ。状態だけ入れておけば、鳴り始めた時点で反映される。
            if app.isRunningOutput || controller.hasTap(forID: app.id) {
                controller.restore(state, for: app)
            } else {
                controller.seed(state, for: app)
            }
        }

        refresh(with: enumerated)
    }

    /// 振り分けを解いたアプリに、既定出力で覚えていた音量を入れ直す。
    ///
    /// これが無いと、振り分け先で使っていた音量をそのまま既定出力の記憶として
    /// 書き込んでしまい、既定出力に覚えていた音量が黙って消える。
    /// メニューから手動で「既定の出力」へ戻したときは setOutputDevice() が
    /// 同じことをしている。自動復旧のときだけ挙動が違う理由は無い。
    ///
    /// 記憶が無いデバイスへ移った場合は何もしない。いまの音量がそのまま
    /// 引き継がれて記憶される（applyMemoryForCurrentDevice と同じ方針）。
    private func applyDefaultDeviceMemory(for app: AudioApp) {
        guard let device = currentDefaultDeviceUID,
              let remembered = storedSettings(for: app).perDevice[device] else { return }

        // 振り分け先は既に nil へ直っている。音量とミュートだけ入れ替える。
        var state = controller.state(forID: app.id)
        state.volume = remembered.volume
        state.muted = remembered.muted

        // 鳴っていないアプリにタップは張らない。controller.setVolume() を使うと
        // 張ってしまうため、状態の入れ方を再生中かどうかで分ける。
        if app.isRunningOutput || controller.hasTap(forID: app.id) {
            controller.restore(state, for: app)
        } else {
            controller.seed(state, for: app)
        }
    }

    /// タップの張り替え失敗（＝いま無音）の印を一覧へ反映する。
    /// 復旧したら印は消える。
    private func syncTapTrouble() {
        for index in apps.indices {
            let id = apps[index].id
            let silenced = controller.isSilencedByFailedRebuild(id: id)
            if silenced {
                if apps[index].trouble != .silenced { apps[index].trouble = .silenced }
            } else if apps[index].trouble == .silenced {
                apps[index].trouble = nil
            }
            let metered = controller.hasFreshTap(for: apps[index].app)
            if apps[index].metered != metered { apps[index].metered = metered }
        }
    }

    /// デバイス構成の変化をまとめて処理する（連続通知を 1 回に束ねる）。
    ///
    /// 機器の抜き差し 1 回につき通知は何度も飛ぶ。そのたびに下の処理を走らせると、
    /// アプリ一覧の再列挙（プロセスごとの sysctl と親 pid 探索）、アイコンの取得、
    /// TCC の dlopen、SMAppService への問い合わせまでが毎回メインスレッドで動く。
    ///
    /// 束ねても判定は遅れない。タップの生死に使う liveDeviceUIDs は
    /// MixerController 側のリスナーが同期的に更新しているため、
    /// ここで待つのは画面と保存内容の更新だけ。
    private func scheduleDeviceResync() {
        deviceResyncWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { guard let self else { return }; self.handleDeviceListChanged() }
        }
        deviceResyncWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// デバイスの構成が変わった。振り分け先が無くなったアプリを既定出力へ戻し、
    /// 保存内容を直したうえで、選択肢の一覧も入れ替える。
    ///
    /// 直す相手がいなくても最後まで進むこと。デバイスが増えただけのときに
    /// 何もしないと、増えたデバイスが出力先メニューに出てこない。既定出力に
    /// なるデバイス（ヘッドフォン等）は別の通知で拾えるが、既定にならない
    /// デバイス（HDMI ディスプレイ、2 台目のインターフェース、仮想デバイス）は
    /// この通知しか手がかりが無い。
    private func handleDeviceListChanged() {
        let enumerated = AudioAppEnumerator.enumerate()
        let repaired = controller.repairMissingRoutes(apps: enumerated)
        for app in enumerated where repaired.contains(app.id) {
            // 保存より先に音量を入れ替えること。順序が逆だと、振り分け先で
            // 使っていた音量を既定出力の記憶として書き込んでしまう。
            applyDefaultDeviceMemory(for: app)
            saveSetting(for: app)
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
        // 既定出力と同じ先を選んだら「振り分けなし」と同じ。ここで UID を
        // 持たせると、意味が無いのにタップを永久に維持することになる。
        let uid = (uid == currentDefaultDeviceUID) ? nil : uid
        var ok = controller.setOutputDevice(uid, for: app)

        // 振り分け先を変えると音の出るデバイスが変わる。そのデバイス用に
        // 覚えている音量があればそちらへ入れ替える（無ければ今の値を覚える）。
        let stored = storedSettings(for: app)
        let device = uid ?? currentDefaultDeviceUID
        if ok, let device, let remembered = stored.perDevice[device] {
            ok = controller.setVolume(remembered.volume, for: app) && ok
            ok = controller.setMuted(remembered.muted, for: app) && ok
        }
        // 切り替えに失敗したら保存しない。コントローラ側は状態を元へ戻すので、
        // ここで書き込むと実際の出力先と保存内容が食い違う。
        if ok { saveSetting(for: app) }

        let state = controller.state(forID: app.id)
        updateRow(app.id) {
            // 要求した値ではなく、実際に通った値を表示する。
            $0.outputDeviceUID = state.outputDeviceUID
            $0.volume = state.volume
            $0.muted = state.muted
            $0.metered = controller.hasFreshTap(for: app)
            $0.trouble = ok ? nil : .notApplied
        }
    }

    /// システム全体の出力先を切り替える（ヘッダーのデバイス名から呼ぶ）。
    func setSystemOutputDevice(_ device: AudioDevice) {
        // 失敗しても名前だけ書き換えると、実際の出力先と表示が食い違う。
        guard CoreAudioObject.setDefaultOutputDevice(device.id) else {
            refreshMaster()
            return
        }
        // 切り替わったことをリスナーが拾うが、表示は即座に追いつかせる。
        outputName = device.name
        currentOutputUID = device.uid
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
        scheduleDuckLevelSave()
        // 発動していないなら 1 秒ごとの判定に任せる。スライダーを動かすたびに
        // プロセス一覧を引き直すのは重い。
        guard duckingReason != nil else { return }

        // 深さを変えただけなので、引き金の判定はやり直さない。スライダーは
        // 値が動くたびにここを呼ぶため、evaluateDucking() を通すと
        // ドラッグ 1 フレームごとに AudioAppEnumerator.enumerate()
        // （音声プロセスごとの sysctl と最大 16 段の親 pid 探索）が走る。
        // 引き金に関わるのは「100% かどうか」だけで、それは一覧を見ずに分かる。
        // 一覧に載っていないタップは setDucking 側が taps 全体への反映で拾う。
        let all = lastEnumeratedApps
        if duckLevel < 0.999 {
            // 倍率を入れ直す。
            applyDucking(active: true, apps: all, excluded: lastExcludedIDs)
        } else {
            // 100% まで絞る＝何も起きない。「絞っています」の帯と行の印は
            // 次のタイマーを待たずにその場で消す。
            duckingReason = nil
            applyDucking(active: false, apps: all, excluded: lastExcludedIDs)
        }
    }

    /// 「下げる音量」の保存を予約する。スライダーは値が変わるたびに
    /// setDuckLevel を呼ぶため、その場で書くと設定デーモンへの書き込みが
    /// イベントレートで走る。倍率の反映は即座、保存だけ束ねる。
    private func scheduleDuckLevelSave() {
        duckLevelSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.duckLevelSaveWork = nil
                self.defaults.set(self.duckLevel, forKey: Self.duckLevelKey)
            }
        }
        duckLevelSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
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
                let all = AudioAppEnumerator.enumerate()
                applyDucking(active: false, apps: all, excluded: Self.communicationIDs(in: all))
            }
            lastEnumeratedApps = []
            lastExcludedIDs = []
            duckTimer?.invalidate()
            duckTimer = nil
            return
        }

        let all = AudioAppEnumerator.enumerate()
        lastEnumeratedApps = all
        lastExcludedIDs = Self.communicationIDs(in: all)
        // 100% まで絞る＝何も起きない。発動中と表示すると嘘になる。
        let reason = duckLevel < 0.999
            ? DuckingDetector.evaluate(apps: all, useMicrophone: duckOnMicrophone)
            : nil

        if reason != duckingReason {
            duckingReason = reason
            applyDucking(active: reason != nil, apps: all, excluded: lastExcludedIDs)
        } else if reason != nil {
            // 発動中も除外集合を最新に保つ。後から鳴り始めた通話アプリは
            // 発動時の集合に入っておらず、放置すると相手の声まで絞ってしまう。
            // 集合に変化が無ければ setDucking は何もしない。
            applyDucking(active: true, apps: all, excluded: lastExcludedIDs)
            // 発動中に鳴り始めたアプリも絞る。
            controller.syncTaps(with: all)
        }
        // 未発動のまま変化が無ければ何もしない。ここで applyDucking(active: false)
        // を通すと releaseMeteringOnlyTaps() まで走り、メーター用のタップを
        // 巻き添えで畳んでしまう。
    }

    /// - Parameter excluded: 通話アプリ自身の id（絞ると相手の声が聞こえなく
    ///   なるので対象外にする）。apps と同じ列挙から作ったものを渡す。
    ///   「下げる音量」のドラッグ中に毎イベント作り直さないよう、ここでは
    ///   計算せず呼び出し側から受け取る。
    private func applyDucking(active: Bool, apps all: [AudioApp], excluded: Set<String>) {
        controller.setDucking(
            multiplier: active ? duckLevel : 1.0,
            excludedIDs: excluded,
            apps: all
        )
        // 「下げる音量」のスライダーはドラッグ中に何度もここへ来る。変化した
        // ときだけ書き込む。毎回代入すると、そのたびに一覧全体が再描画される。
        for index in apps.indices {
            let isExcluded = excluded.contains(apps[index].id)
            let ducked = active && !isExcluded && apps[index].app.isRunningOutput
            let metered = controller.hasFreshTap(for: apps[index].app)
            if apps[index].ducked != ducked { apps[index].ducked = ducked }
            if apps[index].metered != metered { apps[index].metered = metered }
        }

        // 絞るために張ったタップを解放する。ダッキングはポップオーバーを
        // 閉じていても動くため、ここで片付けないと通話が終わったあとも
        // 全アプリの音声が AppMixer 経由のまま残り続ける。
        if !active { controller.releaseMeteringOnlyTaps() }
    }

    /// 通話に使われうるアプリの id 集合（＝ダッキングの対象外）。
    private static func communicationIDs(in apps: [AudioApp]) -> Set<String> {
        Set(apps.filter(DuckingDetector.isCommunicationApp).map(\.id))
    }

    // MARK: - Launch at login

    /// 直近の登録/解除で OS が返したエラー。
    /// 登録できなかった理由は状態からは分からないため、別に持っておく。
    private var launchAtLoginError: String?

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
        case .enabled:
            // 有効になっているなら、前回の失敗はもう関係ない。
            launchAtLoginError = nil
            problem = nil
        case .disabled:
            // 状態からは「登録されていない」ことしか分からない。切り替えに
            // 失敗して戻ってきた場合は、その理由をそのまま見せる。ここで
            // nil にすると、register() が投げた理由が誰にも届かないまま
            // トグルだけが黙って戻る。
            problem = launchAtLoginError
        }
        if launchAtLoginProblem != problem { launchAtLoginProblem = problem }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        launchAtLoginError = LaunchAtLogin.setEnabled(enabled)
        // 実際に登録できたかは OS 側の状態で確認する。
        refreshLaunchAtLogin()
    }

    func openLoginItemsSettings() {
        LaunchAtLogin.openSettings()
    }

    /// メーターがまだ出ていない再生中のアプリを 1 つだけ拾ってタップを張る。
    private func attachNextMeteringTap() {
        // まだ一度も許可を求めていないうちは、こちらからタップを作らない。
        // 作ると OS の録音許可ダイアログが勝手に前に出て、ポップオーバーが
        // 閉じてしまう。ユーザーが「許可」を押すまでは待つ。
        guard permission == .authorized || hasRequestedPermission else { return }
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
            // 張れたなら設定は反映されている。一覧の作り直しを待たずにここで
            // 印を外す（作り直しは顔ぶれが変わったときしか走らない）。
            if apps[index].trouble == .notApplied { apps[index].trouble = nil }
        } else {
            meteringFailures[app.id, default: 0] += 1
        }
        apps[index].metered = controller.hasFreshTap(for: app)
        // 失敗しても音量設定そのものが効いていないとは限らないので、
        // 既に失敗表示が無い行にだけ印を付ける。
        if !ok && apps[index].trouble == nil && apps[index].volume < 0.999 {
            apps[index].trouble = .notApplied
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
        let uid = currentDefaultDeviceUID
        if currentOutputUID != uid { currentOutputUID = uid }
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

        // システム設定やダイアログ側で許可された場合、こちらは何も知らされない。
        // 定期的に見直さないと「許可が必要です」の帯が出たままになる。
        if meterTick % 30 == 15, permission != .authorized {
            let current = AudioCapturePermission.current()
            if permission != current { permission = current }
        }

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
            let level = controller.level(forID: apps[index].id)
            let metered = controller.hasFreshTap(for: apps[index].app)
            if apps[index].level != level { apps[index].level = level }
            if apps[index].metered != metered { apps[index].metered = metered }
        }
    }

    // MARK: - Per-app control

    func setVolume(_ volume: Float, for app: AudioApp) {
        let ok = controller.setVolume(volume, for: app)
        // 効いていない値を保存しない。保存すると、次回以降も「30% のはずが
        // 100% で鳴る」状態が復元され続ける。
        if ok {
            scheduleSave(for: app)
        } else {
            // 反映に失敗したら予約も取り下げる。予約は発火時点の状態を
            // 書くため、残すと反映できなかった値まで保存されてしまう。
            pendingSaves.removeValue(forKey: app.id)?.work.cancel()
        }
        updateRow(app.id) {
            $0.volume = volume
            $0.metered = controller.hasFreshTap(for: app)
            $0.trouble = ok ? nil : .notApplied
        }
    }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        let ok = controller.setMuted(muted, for: app)
        if ok { saveSetting(for: app) }
        updateRow(app.id) {
            $0.muted = muted
            $0.metered = controller.hasFreshTap(for: app)
            $0.trouble = ok ? nil : .notApplied
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
        hasRequestedPermission = true
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
        // 終了通知が届く前に、保存待ちの設定を書き切り、確実にタップを
        // 解除して各アプリの音声を戻す。
        flushPendingSaves()
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
    ///
    /// 形が変わっても古い保存内容を捨てずに読めるよう、版番号を持たせ、
    /// 各項目は「無ければ既定値」で読む。新しい版が増えた項目を、
    /// 古いアプリが読み落として黙って消す事故を避けるための備え。
    private struct StoredSettings: Codable {
        /// この形式の版。読み書きの互換判断に使う。
        var version: Int = StoredSettings.currentVersion
        /// 振り分け先（nil なら既定出力に追従）。
        var outputDeviceUID: String?
        /// 出力デバイス UID -> 音量設定。
        var perDevice: [String: DeviceVolume] = [:]
        /// 最後に使った音量。まだ記憶の無いデバイスへ移ったときの引き継ぎ元。
        /// これが無いと、鳴っていない間にデバイスが変わったアプリだけ
        /// 100% で鳴り出してしまう（鳴っていた場合は引き継がれるのに）。
        var lastKnown: DeviceVolume?

        static let currentVersion = 1

        init(outputDeviceUID: String? = nil) {
            self.outputDeviceUID = outputDeviceUID
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // 版が無いものは v1 より前の何かとして扱う。いまのところ
            // 出荷済みの旧形式は無いので、既定値のまま読み進めればよい。
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
            outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
            perDevice = try container.decodeIfPresent(
                [String: DeviceVolume].self, forKey: .perDevice) ?? [:]
            lastKnown = try container.decodeIfPresent(DeviceVolume.self, forKey: .lastKnown)
        }
    }

    /// 読み込んだ保存内容と、それを書き戻してよいか。
    private struct LoadedSettings {
        var settings = StoredSettings()
        /// このアプリが理解できない内容が入っているか。
        /// true の間は書き込まない（知らない項目ごと踏み潰さないため）。
        var isForeign = false
    }

    private func storageKey(for app: AudioApp) -> String? {
        app.bundleID.map { "appmixer.setting.\($0)" }
    }

    /// いまそのアプリの音が出ているデバイスの UID。
    /// 振り分けていればその先、していなければ既定出力。
    private func deviceKey(for app: AudioApp) -> String? {
        if let routed = controller.state(forID: app.id).outputDeviceUID { return routed }
        return currentDefaultDeviceUID
    }

    /// いまの既定出力デバイスの UID。読めなければ nil。
    /// 読めないときに固定の代用キーへ書くと、別々のデバイスの記憶が
    /// 1 つに混ざったうえ、UID が読めるようになった途端に行方不明になる。
    private var currentDefaultDeviceUID: String? {
        CoreAudioObject.deviceUID(CoreAudioObject.defaultOutputDeviceID())
    }

    private func loadStored(for app: AudioApp) -> LoadedSettings {
        guard let key = storageKey(for: app), let data = defaults.data(forKey: key) else {
            return LoadedSettings()
        }
        guard let stored = try? JSONDecoder().decode(StoredSettings.self, from: data) else {
            // 壊れているか、まったく別の形式。読める情報が無いので既定で動くが、
            // 中身が分からないものを上書きはしない。
            AppLog.settings.error("Unreadable settings for \(app.bundleID ?? "?", privacy: .private)")
            return LoadedSettings(isForeign: true)
        }
        // このアプリより新しい版で書かれている。読める範囲は使うが、
        // 書き戻すと知らない項目が落ちるため上書きはしない。
        return LoadedSettings(
            settings: stored,
            isForeign: stored.version > StoredSettings.currentVersion
        )
    }

    private func storedSettings(for app: AudioApp) -> StoredSettings {
        loadStored(for: app).settings
    }

    /// 保存を予約する（0.5 秒以内に次が来たら置き換え）。saveSetting は
    /// 発火時点の state を書くので、予約が置き換わっても最終値は失われない。
    private func scheduleSave(for app: AudioApp) {
        pendingSaves[app.id]?.work.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pendingSaves[app.id] = nil
                // 予約から発火までの間にアプリごと消えて prune された場合は
                // 書かない。state が無いまま saveSetting を呼ぶと、既定値
                // （100%・ミュート解除）で保存済みの記憶を上書きしてしまう。
                guard self.controller.states[app.id] != nil else { return }
                self.saveSetting(for: app)
            }
        }
        pendingSaves[app.id] = (app, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// 予約中の保存をその場で書き切る。終了の経路で呼ぶこと。
    /// 呼ばないと、終了直前の操作だけが保存されないまま失われる。
    private func flushPendingSaves() {
        let pending = pendingSaves
        pendingSaves.removeAll()
        for entry in pending.values {
            entry.work.cancel()
            // 予約後に消えたアプリは書かない（予約の発火側と同じ理由）。
            guard controller.states[entry.app.id] != nil else { continue }
            saveSetting(for: entry.app)
        }
        if duckLevelSaveWork != nil {
            duckLevelSaveWork?.cancel()
            duckLevelSaveWork = nil
            defaults.set(duckLevel, forKey: Self.duckLevelKey)
        }
    }

    private func saveSetting(for app: AudioApp) {
        // ここで直に書くので、同じアプリの予約は同じ内容の書き直しにしか
        // ならない。取り下げる（ミュートや出力先の変更は即時保存のため、
        // 直前のドラッグの予約とここで合流する）。
        pendingSaves.removeValue(forKey: app.id)?.work.cancel()
        guard let key = storageKey(for: app) else { return }
        let loaded = loadStored(for: app)
        // 理解できない保存内容には触れない。ここで書くと、新しい版の
        // AppMixer が残した設定を古い版が黙って削ってしまう。
        guard !loaded.isForeign else { return }

        let state = controller.state(forID: app.id)
        var stored = loaded.settings
        stored.version = StoredSettings.currentVersion
        stored.outputDeviceUID = state.outputDeviceUID
        let volume = DeviceVolume(volume: state.volume, muted: state.muted)
        // デバイスの UID が読めないときは、そのデバイスぶんの記憶は書かない。
        // 代用キーへ書くと別デバイスの記憶と混ざってしまう。
        if let device = deviceKey(for: app) { stored.perDevice[device] = volume }
        stored.lastKnown = volume
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: key)
        }
    }

    private func loadSetting(for app: AudioApp) -> MixerController.State? {
        guard storageKey(for: app) != nil else { return nil }
        let stored = storedSettings(for: app)
        // 振り分け先が決まっているなら、その先のデバイスの音量を読む。
        let device = stored.outputDeviceUID ?? currentDefaultDeviceUID ?? ""
        // このデバイスの記憶が無ければ、最後に使っていた音量を引き継ぐ。
        // 既定（100%）に落とすと、鳴っていない間にヘッドフォンへ切り替わった
        // アプリだけが次に鳴った瞬間に爆音になる。
        guard let saved = stored.perDevice[device] ?? stored.lastKnown else {
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
