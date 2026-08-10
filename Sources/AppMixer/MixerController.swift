import AppKit
import CoreAudio
import os

// アプリ別音量の状態管理とタップの生成/破棄、マスター音量を統括する。
//
// ポリシー:
//   - 実効ゲイン = muted ? 0 : volume
//   - 実効ゲインが ~1.0 のときはタップを張らず通常再生（低負荷）
//   - それ以外はタップを起動し gain を反映
//   - マスター音量/ミュートは既定出力デバイス自体の音量/ミュートで実現
//   - 既定出力デバイスが変わったら、生きているタップを作り直す

final class MixerController {

    struct State: Equatable {
        var volume: Float = 1.0
        var muted: Bool = false
        /// 出力先デバイスの UID。nil なら既定出力に追従する。
        var outputDeviceUID: String?
        /// ユーザー操作による音量（ダッキングを含まない）。
        var userGain: Float { muted ? 0.0 : volume }
        /// 既定と異なる設定を持っているか（＝タップを維持すべきか）。
        var isCustomized: Bool { userGain < 0.999 || outputDeviceUID != nil }
    }

    /// ダッキング中に適用する倍率（1.0 で無効）。
    private(set) var duckMultiplier: Float = 1.0
    /// ダッキングの対象外にするアプリ（通話アプリ自身など）。
    private var duckExcludedIDs: Set<String> = []

    /// そのアプリに実際に適用すべきゲイン。
    private func targetGain(for id: String) -> Float {
        let user = (states[id] ?? State()).userGain
        guard duckMultiplier < 1.0, !duckExcludedIDs.contains(id) else { return user }
        return user * duckMultiplier
    }

    private(set) var states: [String: State] = [:]
    private var taps: [String: ProcessTap] = [:]
    /// 破棄に失敗し、再試行が必要なタップ。放置すると対象アプリが無音のままになる。
    private var pendingTeardown: [ProcessTap] = []
    private var teardownRetryScheduled = false
    /// 既定出力の切り替えに追従できなかったアプリ。古い出力先を指したままなので
    /// 実際には無音になっている。復旧するまで再試行し、画面にも印を出す。
    private var rebuildFailedIDs: Set<String> = []
    private var rebuildRetryScheduled = false
    /// 張り替えに失敗した回数（アプリごと）。
    /// 全体で 1 つのカウンタにすると、慢性的に失敗するアプリが 1 つあるだけで
    /// 直後に失敗した別のアプリの復旧まで最大 30 秒待たされる。
    private var rebuildAttempts: [String: Int] = [:]
    /// メーター用タップを 1 つずつ解放している最中か。
    private var draining = false
    private var deviceListenerInstalled = false
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    /// 直前の既定出力デバイス。同じデバイスでの通知を無視するために持つ。
    private var lastDefaultDeviceID: AudioObjectID = .unknown

    /// マスター音量/ミュートが外部（F11/F12 やシステム設定）で変わったときに呼ばれる。
    var onMasterChanged: (() -> Void)?

    /// 音声プロセスの増減（アプリ起動/終了、ブラウザの新規タブ等）を検知したときに呼ばれる。
    var onProcessListChanged: (() -> Void)?

    /// 既定出力デバイスが切り替わったときに呼ばれる（タップの張り直しは済んでいる）。
    var onDefaultDeviceChanged: (() -> Void)?

    /// 接続されているデバイスの構成が変わったときに呼ばれる。
    var onDeviceListChanged: (() -> Void)?

    /// タップの不調（張り替え失敗とその復旧）が変化したときに呼ばれる。
    var onTapTroubleChanged: (() -> Void)?

    /// 既定出力の切り替えに追従できず、いま音が出ていないアプリか。
    func isSilencedByFailedRebuild(id: String) -> Bool {
        rebuildFailedIDs.contains(id)
    }

    /// 「追従できず無音」の印を外す。実際に音が出る状態へ戻した経路すべてから呼ぶ。
    ///
    /// 印を消し忘れると二重に害がある。`hasFreshTap` はこの印だけで false を
    /// 返すため、(1) 画面に赤い印が出たまま残り、(2) 呼び出し側が「まだタップが
    /// 無い」と判断して張り直しを繰り返す。集約デバイスの生成/破棄が続くと、
    /// そのデバイスで再生中の全アプリが音飛びする。
    ///
    /// - Returns: 実際に印が外れたら true（通知するかの判断に使う）。
    @discardableResult
    private func clearRebuildFailure(_ id: String) -> Bool {
        rebuildAttempts[id] = nil
        return rebuildFailedIDs.remove(id) != nil
    }

    /// いま存在する出力デバイスの UID。振り分け先が生きているかの判定に使う。
    private var liveDeviceUIDs: Set<String> = []

    init() {
        refreshLiveDeviceUIDs()
        installDefaultDeviceListener()
        installMasterListeners()
        installProcessListListener()
        installDeviceListListener()
    }

    deinit {
        removeDefaultDeviceListener()
        removeMasterListeners()
        removeProcessListListener()
        removeDeviceListListener()
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }

    // MARK: - Per-app state

    func state(forID id: String) -> State {
        states[id] ?? State()
    }

    func level(forID id: String) -> Float {
        taps[id]?.level ?? 0
    }

    /// タップが張られているか（＝メーターを表示できるか）。
    func hasTap(forID id: String) -> Bool {
        taps[id] != nil
    }

    /// 音量を設定する。実際に反映できたら true（false ならタップを張れていない）。
    @discardableResult
    func setVolume(_ volume: Float, for app: AudioApp) -> Bool {
        var s = states[app.id] ?? State()
        s.volume = max(0.0, min(1.0, volume))
        states[app.id] = s
        return apply(s, for: app)
    }

    @discardableResult
    func setMuted(_ muted: Bool, for app: AudioApp) -> Bool {
        var s = states[app.id] ?? State()
        s.muted = muted
        states[app.id] = s
        return apply(s, for: app)
    }

    /// 出力先デバイスを設定する（nil で既定出力に戻す）。
    @discardableResult
    func setOutputDevice(_ uid: String?, for app: AudioApp) -> Bool {
        let previous = states[app.id]?.outputDeviceUID
        var s = states[app.id] ?? State()
        s.outputDeviceUID = uid
        states[app.id] = s

        // 既定出力へ戻した上に音量も原音なら、タップは不要なので畳む。
        if !s.isCustomized, taps[app.id] != nil, duckMultiplier >= 1.0 {
            if let tap = taps.removeValue(forKey: app.id) {
                tap.invalidate()
                retireIfNeeded(tap)
            }
            // タップを畳んだアプリは通常経路へ戻る。「追従できず無音」では
            // なくなったので印を外す。releaseMeteringOnlyTaps と同じ理由で、
            // 残すと次に一覧を作り直したときに赤い印が復活する。
            if clearRebuildFailure(app.id) { onTapTroubleChanged?() }
            return true
        }

        let ok = apply(s, for: app)
        if !ok {
            // 切り替えに失敗したら音は元のデバイスから出続ける。状態だけ
            // 新しい先に書き換えると、表示・保存・以降の音量記憶がすべて
            // 実際と食い違うため、元に戻す。
            var reverted = states[app.id] ?? State()
            reverted.outputDeviceUID = previous
            states[app.id] = reverted
        }
        return ok
    }

    // MARK: - Ducking

    /// ダッキングの適用状態を更新する。
    /// - Parameters:
    ///   - multiplier: 1.0 で解除。0.2 なら 20% まで絞る。
    ///   - excludedIDs: 対象外にするアプリ（通話アプリ自身）。
    ///   - apps: 現在のアプリ一覧（タップを張る対象の判定に使う）。
    func setDucking(multiplier: Float, excludedIDs: Set<String>, apps: [AudioApp]) {
        let changed = (multiplier != duckMultiplier) || (excludedIDs != duckExcludedIDs)
        duckMultiplier = max(0.0, min(1.0, multiplier))
        duckExcludedIDs = excludedIDs
        guard changed else { return }

        var needsTap: [AudioApp] = []
        for app in apps {
            let state = states[app.id] ?? State()
            let beingDucked = duckMultiplier < 1.0 && !duckExcludedIDs.contains(app.id)

            if beingDucked && app.isRunningOutput {
                if taps[app.id] != nil {
                    // 既にタップがあるなら倍率を入れるだけ。ゲインの適用は
                    // IOProc 側でフェードするので、ここでは即座でよい。
                    apply(state, for: app)
                } else {
                    // 新しく張るぶんは後回しにする。まとめて作ると集約デバイスの
                    // 生成が連続し、そのデバイスで再生中の音がすべて飛ぶ。
                    needsTap.append(app)
                }
            } else if let tap = taps[app.id] {
                // 解除。設定が無ければ後で解放されるが、まず音量を戻す。
                tap.gain = targetGain(for: app.id)
            }
        }

        duckPending = needsTap
        attachNextDuckTap()
    }

    /// ダッキングのために新しく張る必要があるアプリ。1 つずつ処理する。
    private var duckPending: [AudioApp] = []
    private var duckAttachScheduled = false

    /// 待ち行列へ足す（既に並んでいるものは重ねない）。
    private func enqueueDuckTaps(_ apps: [AudioApp]) {
        guard !apps.isEmpty else { return }
        let queued = Set(duckPending.map(\.id))
        duckPending.append(contentsOf: apps.filter { !queued.contains($0.id) })
        attachNextDuckTap()
    }

    /// 待ち行列から 1 つだけタップを張り、残りは間隔をあけて続ける。
    /// releaseMeteringOnlyTaps と同じ理由で、まとめて作らない。
    private func attachNextDuckTap() {
        // 待っている間に解除されたら、残りはもう要らない。
        guard duckMultiplier < 1.0 else {
            duckPending.removeAll()
            return
        }
        guard !duckPending.isEmpty else { return }

        let app = duckPending.removeFirst()
        // 対象外に変わっていることがある（通話アプリと判定され直した等）。
        if !duckExcludedIDs.contains(app.id) {
            apply(states[app.id] ?? State(), for: app)
        }

        guard !duckPending.isEmpty, !duckAttachScheduled else { return }
        duckAttachScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.duckAttachScheduled = false
            self.attachNextDuckTap()
        }
    }

    /// 永続化した状態を復元する（デフォルトと異なる場合のみタップを張る）。
    func restore(_ state: State, for app: AudioApp) {
        states[app.id] = state
        apply(state, for: app)
    }

    func reset(for app: AudioApp) {
        states[app.id] = State()
        if let tap = taps[app.id] {
            tap.invalidate()
            retireIfNeeded(tap)
        }
        taps.removeValue(forKey: app.id)
        clearRebuildFailure(app.id)
    }

    /// 現在のアプリ一覧に合わせてタップを同期する。
    /// プロセスオブジェクトが入れ替わったアプリはタップを張り直す。
    func syncTaps(with apps: [AudioApp]) {
        refreshDuckPending(with: apps)

        var needsDuckTap: [AudioApp] = []
        for app in apps {
            // 設定も無くダッキング対象でもないアプリにタップは要らない。
            let state = states[app.id] ?? State()
            let beingDucked = duckMultiplier < 1.0
                && !duckExcludedIDs.contains(app.id) && app.isRunningOutput
            guard state.isCustomized || beingDucked else { continue }
            // 鳴っていないアプリに新しくタップは張らない。停止中のアプリにも
            // 保存済みの設定を入れてあるため、ここで一斉に張ると集約デバイスが
            // まとめて作られ、そのデバイスで再生中の音がすべて飛ぶ。
            // 鳴り始めれば一覧の作り直しを経てここへ戻ってくる。
            // 既にタップを持っているものは、張り替えが要るので通す。
            guard app.isRunningOutput || taps[app.id] != nil else { continue }

            // ユーザーの設定は無く、ダッキングのためだけに新しく張るもの。
            // ここで同期ループのまま作ると、setDucking が 0.08 秒間隔に
            // 分けている意味が無くなる。待ち行列へ回して入口を 1 つにする。
            if taps[app.id] == nil, !state.isCustomized {
                needsDuckTap.append(app)
                continue
            }
            apply(state, for: app)
        }
        enqueueDuckTaps(needsDuckTap)
    }

    /// 待ち行列の中身を最新の列挙結果へ入れ替える。
    ///
    /// 待っている間にアプリが止まったり、音声ヘルパーが入れ替わったりする。
    /// 積んだ時点の値のまま張ると、鳴っていないアプリや死んだプロセス
    /// オブジェクトを指すタップを作ってしまう。
    private func refreshDuckPending(with apps: [AudioApp]) {
        guard !duckPending.isEmpty else { return }
        let latest = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        duckPending = duckPending.compactMap { pending -> AudioApp? in
            guard let fresh = latest[pending.id], fresh.isRunningOutput else { return nil }
            return fresh
        }
    }

    /// メーター表示のためだけに張ったタップ（音量を変えていないもの）を破棄する。
    /// 表示していない間まで全アプリの音声を経由させ続けない。
    ///
    /// 一度に全部壊すと、集約デバイスの破棄がまとめて走って音飛びし、
    /// メインスレッドも詰まるため、1 つずつ間隔をあけて解放する。
    func releaseMeteringOnlyTaps() {
        retryPendingTeardown()

        // 音量も出力先も既定のままで、いまダッキングもしていないタップだけを解放する。
        // ルーティング中のアプリはタップを外すと元のデバイスへ戻ってしまうし、
        // ダッキング中のアプリはタップを外すと音量が戻ってしまう。
        let releasable = taps.keys.filter { id in
            guard !(states[id] ?? State()).isCustomized else { return false }
            let beingDucked = duckMultiplier < 1.0 && !duckExcludedIDs.contains(id)
            return !beingDucked
        }
        guard let id = releasable.first else {
            draining = false
            return
        }
        if let tap = taps.removeValue(forKey: id) {
            tap.invalidate()
            retireIfNeeded(tap)
        }
        // タップを畳んだアプリは通常経路へ戻る。「追従できず無音」ではなく
        // なったので印を外す。残すと、鳴っているのに赤い印が出たままになる。
        if clearRebuildFailure(id) { onTapTroubleChanged?() }

        guard releasable.count > 1 else {
            draining = false
            return
        }
        draining = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.draining else { return }
            self.releaseMeteringOnlyTaps()
        }
    }

    /// 解放処理を中断する（表示が再開されたときに呼ぶ）。
    func cancelMeteringRelease() {
        draining = false
    }

    /// 全タップを破棄して、各アプリの音声を通常経路へ戻す。
    /// 終了時に必ず呼ぶこと（呼ばないとアプリが無音のままになりうる）。
    func shutdown() {
        for tap in taps.values {
            tap.invalidate()
            // 一度で破棄できないことがあるため、その場で再試行する。
            if !tap.isFullyTornDown { tap.invalidate() }
            // それでも駄目なら再試行リストへ。ここで手放すと、終了が
            // 中断された場合に対象アプリが無音のまま記録も残らない。
            retireIfNeeded(tap)
        }
        taps.removeAll()
        retryPendingTeardown()
    }

    /// 消えたアプリのタップと状態を掃除する。
    /// （音量設定そのものは UserDefaults 側に残るため、再検出時に復元される）
    func prune(aliveIDs: Set<String>) {
        retryPendingTeardown()
        for id in taps.keys where !aliveIDs.contains(id) {
            if let tap = taps[id] {
                tap.invalidate()
                retireIfNeeded(tap)
            }
            taps.removeValue(forKey: id)
        }
        states = states.filter { aliveIDs.contains($0.key) }
        rebuildFailedIDs.formIntersection(aliveIDs)
        rebuildAttempts = rebuildAttempts.filter { aliveIDs.contains($0.key) }
    }

    /// 音量設定を反映する。要求どおりの状態にできたら true。
    @discardableResult
    private func apply(_ state: State, for app: AudioApp) -> Bool {
        let gain = targetGain(for: app.id)

        if let tap = taps[app.id] {
            // 同じアプリでも、再起動や新しい音声ヘルパー（ブラウザの新規タブ等）で
            // プロセスオブジェクトが入れ替わる。その場合は張り直さないと、
            // 死んだ ID をタップしたままになり新しい音声に効かなくなる。
            // 列挙順は保証されないため集合で比較する。
            // 出力先を変えた場合も集約デバイスごと作り直しになる。
            // 既定出力の切り替えに追従できていないタップは、見た目の条件が
            // 揃っていても実際には音を出せない。素通しさせず必ず張り直す。
            if !rebuildFailedIDs.contains(app.id),
               Self.sameProcesses(tap.processObjectIDs, app.processObjectIDs),
               tap.outputDeviceUID == state.outputDeviceUID {
                // 100% でもタップは張ったままにする（素通し）。スライダーを
                // 100% 付近で往復するたびに集約デバイスを作り直すと、その
                // デバイスで再生中の全アプリが音飛びするため。
                tap.gain = gain
                return true
            }
            // 先に新しいタップを起動してから古い方を破棄する（make-before-break）。
            // 先に破棄すると、その間だけ対象アプリが通常経路に戻り、
            // ミュート中でも全音量で鳴ってしまう。
            if let replacement = makeTap(for: app, gain: gain) {
                tap.invalidate()
                retireIfNeeded(tap)
                taps[app.id] = replacement
                if clearRebuildFailure(app.id) { onTapTroubleChanged?() }
                return true
            }
            // 張り替えに失敗したら、古いタップを残す方が安全（設定を失わない）。
            AppLog.audio.error("Keeping previous tap for \(app.name, privacy: .private); rebuild failed")
            return false
        }

        // タップが無く、原音のまま既定出力でよいなら何もしない。
        if gain >= 0.999 && state.outputDeviceUID == nil { return true }

        guard let tap = makeTap(for: app, gain: gain) else { return false }
        taps[app.id] = tap
        if clearRebuildFailure(app.id) { onTapTroubleChanged?() }
        return true
    }

    /// 現在の設定に一致するタップが張られているか。
    /// 古い（ヘルパーや出力先が変わった）タップは「無し」と同じ扱いにする。
    func hasFreshTap(for app: AudioApp) -> Bool {
        guard let tap = taps[app.id] else { return false }
        // 既定出力の切り替えに追従できなかったタップは、もう音を運んでいない。
        if rebuildFailedIDs.contains(app.id) { return false }
        // 振り分け先が引き抜かれたタップは「生きている」と見なさない。
        // 死んだデバイスを指したままだと、対象アプリは .mutedWhenTapped で
        // 無音のまま取り残され、張り直す経路も塞がってしまう。
        if let uid = tap.outputDeviceUID, !liveDeviceUIDs.contains(uid) { return false }
        guard tap.outputDeviceUID == (states[app.id] ?? State()).outputDeviceUID else { return false }
        return Self.sameProcesses(tap.processObjectIDs, app.processObjectIDs)
    }

    /// 音声プロセスの顔ぶれが同じか。列挙順は保証されないので順序は見ない。
    ///
    /// 集合を作らずに突き合わせる。この判定は表示の更新に合わせて 30fps で
    /// 全アプリぶん呼ばれるため、Set を作ると毎秒数百回の確保になる。
    /// どちらも HAL のプロセス一覧由来で重複が無いため、個数が同じで
    /// 片側が全部含まれていれば集合として等しい。
    private static func sameProcesses(_ a: [AudioObjectID], _ b: [AudioObjectID]) -> Bool {
        guard a.count == b.count else { return false }
        return a.allSatisfy { b.contains($0) }
    }

    /// 振り分け先が無くなったアプリを既定出力へ戻す。戻したアプリの id を返す。
    ///
    /// 状態は必ず既定出力へ書き換える（そこが行き先だと決めたため）。ただし
    /// 実際に張り直せたかは別で、失敗すると古いタップが消えたデバイスを指した
    /// ままになり、そのアプリは無音になる。黙って「直した」ことにせず印を付け、
    /// 再試行の対象に入れる。
    @discardableResult
    func repairMissingRoutes(apps: [AudioApp]) -> [String] {
        refreshLiveDeviceUIDs()
        var repaired: [String] = []
        let before = rebuildFailedIDs
        for app in apps {
            guard let uid = states[app.id]?.outputDeviceUID,
                  !liveDeviceUIDs.contains(uid) else { continue }
            var s = states[app.id] ?? State()
            s.outputDeviceUID = nil
            states[app.id] = s
            // 行き先は直したので、鳴らせたかに関わらず保存の対象にする。
            repaired.append(app.id)

            // 鳴っていないアプリに、ここで新しくタップを張らない。停止中の
            // アプリにも保存済みの設定（振り分け先を含む）が入っているため、
            // これが無いと引き抜き 1 回で、黙っているアプリのぶんまで集約
            // デバイスがまとめて作られ、既定出力で再生中の音が飛ぶ。
            // 状態を既定出力へ直しておけば、鳴り始めた時点で syncTaps が拾う。
            guard app.isRunningOutput || taps[app.id] != nil else { continue }

            if apply(s, for: app) {
                clearRebuildFailure(app.id)
            } else {
                rebuildFailedIDs.insert(app.id)
            }
        }
        finishRebuildPass(previousFailures: before)
        return repaired
    }

    private func refreshLiveDeviceUIDs() {
        liveDeviceUIDs = Set(AudioDeviceEnumerator.outputDevices().map(\.uid))
    }

    /// タップを張らずに状態だけ入れる（鳴っていないアプリ用）。
    func seed(_ state: State, for app: AudioApp) {
        states[app.id] = state
    }

    /// メーター表示のためにタップを用意する（音量は変えない）。
    /// タップを張らないとそのアプリのレベルは計測できないため、
    /// 再生中のアプリには原音のままタップを張る。
    /// 集約デバイスの生成は一度に一つだけ行い、まとめて作らない
    /// （連続して作るとそのデバイス上の全再生が音飛びする）。
    @discardableResult
    func ensureMeteringTap(for app: AudioApp) -> Bool {
        cancelMeteringRelease()
        let gain = targetGain(for: app.id)

        if let tap = taps[app.id] {
            if hasFreshTap(for: app) { return true }
            // ヘルパーや出力先が変わったタップは作り直す。
            // 新しい方を起動してから古い方を破棄する。
            guard let replacement = makeTap(for: app, gain: gain) else { return false }
            tap.invalidate()
            retireIfNeeded(tap)
            taps[app.id] = replacement
            // ここで張り直せたということは、もう無音ではない。印を外さないと
            // hasFreshTap が false を返し続け、0.5 秒ごとに呼ばれるこの経路が
            // 同じアプリを選び直して集約デバイスを作り直し続ける。
            if clearRebuildFailure(app.id) { onTapTroubleChanged?() }
            return true
        }

        guard let tap = makeTap(for: app, gain: gain) else { return false }
        taps[app.id] = tap
        if clearRebuildFailure(app.id) { onTapTroubleChanged?() }
        return true
    }

    private func makeTap(for app: AudioApp, gain: Float) -> ProcessTap? {
        let tap = ProcessTap(
            processObjectIDs: app.processObjectIDs,
            outputDeviceUID: (states[app.id] ?? State()).outputDeviceUID
        )
        // 新しいタップは目標ゲインから始める（開始時にフェードさせない）。
        tap.state.currentGain = gain
        tap.gain = gain
        do {
            try tap.activate()
            return tap
        } catch {
            AppLog.audio.error("Failed to activate tap for \(app.name, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// 破棄しきれなかったタップは、対象アプリを無音のまま残すため保持して再試行する。
    private func retireIfNeeded(_ tap: ProcessTap) {
        guard !tap.isFullyTornDown else { return }
        pendingTeardown.append(tap)
        // 何かのきっかけを待つのではなく、自分で再試行を予約する。
        // 放置すると、ユーザーが触っていないアプリが無音のまま取り残される。
        scheduleTeardownRetry()
    }

    private func scheduleTeardownRetry() {
        guard !teardownRetryScheduled, !pendingTeardown.isEmpty else { return }
        teardownRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.teardownRetryScheduled = false
            self.retryPendingTeardown()
            self.scheduleTeardownRetry()
        }
    }

    /// 破棄に失敗したタップの再破棄を試みる。
    private func retryPendingTeardown() {
        guard !pendingTeardown.isEmpty else { return }
        for tap in pendingTeardown { tap.invalidate() }
        pendingTeardown.removeAll { $0.isFullyTornDown }
    }

    // MARK: - Master (default output device)

    var masterVolumeSupported: Bool {
        CoreAudioObject.outputVolumeSupported(CoreAudioObject.defaultOutputDeviceID())
    }

    /// ミュート操作ができるか。専用のミュートを持たないデバイスでも、
    /// 音量を 0 にする代用が効くならボタンは使えるままにする。
    var masterMuteSupported: Bool {
        let deviceID = CoreAudioObject.defaultOutputDeviceID()
        return CoreAudioObject.outputMuteSupported(deviceID)
            || CoreAudioObject.outputVolumeSupported(deviceID)
    }

    /// 代用ミュート中の復帰先の音量。nil なら代用ミュートはしていない。
    private var mutedFromVolume: Float?

    func masterVolume() -> Float {
        CoreAudioObject.outputVolume(CoreAudioObject.defaultOutputDeviceID()) ?? 1.0
    }

    func masterMuted() -> Bool {
        let deviceID = CoreAudioObject.defaultOutputDeviceID()
        if CoreAudioObject.outputMuteSupported(deviceID) {
            return CoreAudioObject.outputMuted(deviceID)
        }
        // 代用ミュート中でも、外から音量を上げられたらもうミュートではない。
        if mutedFromVolume != nil, masterVolume() > 0.0001 { mutedFromVolume = nil }
        return mutedFromVolume != nil
    }

    @discardableResult
    func setMasterVolume(_ volume: Float) -> Bool {
        // スライダーを動かしたら代用ミュートは解除されたものとして扱う。
        if volume > 0.0001 { mutedFromVolume = nil }
        return CoreAudioObject.setOutputVolume(CoreAudioObject.defaultOutputDeviceID(), volume)
    }

    @discardableResult
    func setMasterMuted(_ muted: Bool) -> Bool {
        let deviceID = CoreAudioObject.defaultOutputDeviceID()
        if CoreAudioObject.outputMuteSupported(deviceID) {
            return CoreAudioObject.setOutputMuted(deviceID, muted)
        }
        // ミュートを持たないデバイス（多くの USB DAC や HDMI 出力）では
        // 音量 0 で代用する。ボタンを無効にしてしまうより、押せば黙る方がよい。
        guard CoreAudioObject.outputVolumeSupported(deviceID) else { return false }
        if muted {
            // 復帰先が 0 だと解除しても無音のままになる。下限を設けておく。
            mutedFromVolume = max(masterVolume(), 0.1)
            return CoreAudioObject.setOutputVolume(deviceID, 0)
        }
        let restore = mutedFromVolume ?? 0.5
        mutedFromVolume = nil
        return CoreAudioObject.setOutputVolume(deviceID, restore)
    }

    func defaultOutputName() -> String {
        CoreAudioObject.deviceName(CoreAudioObject.defaultOutputDeviceID()) ?? "不明な出力デバイス"
    }

    // MARK: - Default output device change

    private func rebuildActiveTaps() {
        // 出力先が変わったので、マスター音量の監視対象も新しいデバイスへ移す。
        reinstallMasterListeners()
        // 代用ミュートの復帰先は前のデバイスの値なので、持ち越さない。
        mutedFromVolume = nil
        onMasterChanged?()

        retryPendingTeardown()

        let before = rebuildFailedIDs
        let snapshot = taps
        for (id, oldTap) in snapshot {
            // 出力先を明示しているタップは既定出力の変更と無関係。
            guard oldTap.followsDefaultOutput else { continue }
            if rebuildTap(id: id, replacing: oldTap) {
                clearRebuildFailure(id)
            } else {
                rebuildFailedIDs.insert(id)
            }
        }
        finishRebuildPass(previousFailures: before)
    }

    /// 既定出力の変更に合わせてタップを 1 つ張り直す。成功で true。
    private func rebuildTap(id: String, replacing oldTap: ProcessTap) -> Bool {
        let newTap = ProcessTap(processObjectIDs: oldTap.processObjectIDs)
        newTap.state.currentGain = oldTap.gain
        newTap.gain = oldTap.gain
        do {
            // 新しい出力先のタップを起動してから古い方を落とす。
            // 逆順にすると、その隙間だけ対象アプリが全音量で鳴る。
            try newTap.activate()
            oldTap.invalidate()
            retireIfNeeded(oldTap)
            taps[id] = newTap
            return true
        } catch {
            // 失敗時は古いタップを残す。破棄してしまうと設定が失われ、
            // ミュート中のアプリが突然鳴り出す。ただし古いタップは既に
            // 使われていないデバイスへ書き出しているため、対象アプリは
            // このあいだ無音になる。放置できないので再試行する。
            AppLog.audio.error("Rebuild tap failed for \(id, privacy: .private): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// 張り替えに失敗したぶんだけ、もう一度試す。
    /// うまくいっているタップまで作り直すと、そのたびに音が飛ぶ。
    private func retryFailedRebuilds() {
        let before = rebuildFailedIDs
        guard !before.isEmpty else { return }
        for id in before {
            // アプリごと消えたか、既定出力へ向ける必要がなくなっていたら、
            // もう追いかける相手がいない。
            //
            // 判定は「古いタップがどこを指しているか」ではなく「いま state が
            // どこを指しているか」で行う。振り分け先が引き抜かれて既定出力へ
            // 戻されたアプリは、古いタップが消えたデバイスを指したままなので、
            // タップ基準で見ると復旧の対象から外れてしまう。
            guard let oldTap = taps[id],
                  (states[id] ?? State()).outputDeviceUID == nil else {
                clearRebuildFailure(id)
                continue
            }
            if rebuildTap(id: id, replacing: oldTap) { clearRebuildFailure(id) }
        }
        finishRebuildPass(previousFailures: before)
    }

    private func finishRebuildPass(previousFailures before: Set<String>) {
        // 復旧した ID の失敗回数は捨てる。残すと、次に失敗したときに
        // 前回の回数を引きずって最初から長い間隔で待つことになる。
        rebuildAttempts = rebuildAttempts.filter { rebuildFailedIDs.contains($0.key) }
        if rebuildFailedIDs != before { onTapTroubleChanged?() }
        scheduleRebuildRetry()
    }

    private func scheduleRebuildRetry() {
        guard !rebuildRetryScheduled, !rebuildFailedIDs.isEmpty else { return }
        rebuildRetryScheduled = true
        // 何度も失敗するデバイスに毎秒張り付いても復旧しない。
        // ただし諦めてしまうと対象アプリが無音のまま残るので、
        // 間隔を伸ばしながら試し続ける。
        //
        // 間隔はいちばん新しく失敗したアプリ（＝試行回数が最も少ないもの）に
        // 合わせる。全体で 1 つのカウンタにすると、慢性的に失敗するアプリの
        // バックオフに引きずられて、直後に失敗した別のアプリが最大 30 秒
        // 無音のまま放置される。
        let attempts = rebuildFailedIDs.map { rebuildAttempts[$0] ?? 0 }.min() ?? 0
        let delay = min(1.5 * pow(2.0, Double(attempts)), 30.0)
        for id in rebuildFailedIDs { rebuildAttempts[id, default: 0] += 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.rebuildRetryScheduled = false
            self.retryFailedRebuilds()
        }
    }

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func installDefaultDeviceListener() {
        guard !deviceListenerInstalled else { return }
        lastDefaultDeviceID = CoreAudioObject.defaultOutputDeviceID()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // 同じデバイスのまま通知が来ることがある。毎回作り直すと、
            // そのたびに全タップの破棄と生成が走って音が飛ぶ。
            let current = CoreAudioObject.defaultOutputDeviceID()
            guard current != self.lastDefaultDeviceID else { return }
            self.lastDefaultDeviceID = current
            self.rebuildActiveTaps()
            // 出力先が変わると「そのデバイスでの音量」も変わるため、
            // 張り直したあとに呼び出し側へ知らせる。
            self.onDefaultDeviceChanged?()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            .system, &defaultDeviceAddress, DispatchQueue.main, block
        )
        if status == noErr {
            deviceListenerBlock = block
            deviceListenerInstalled = true
        }
    }

    private func removeDefaultDeviceListener() {
        guard deviceListenerInstalled, let block = deviceListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            .system, &defaultDeviceAddress, DispatchQueue.main, block
        )
        deviceListenerBlock = nil
        deviceListenerInstalled = false
    }

    // MARK: - Master volume / mute listeners
    //
    // F11/F12 やシステム設定でマスター音量が変わったことを検知する。
    // これが無いと、ポップオーバーを開き直すまで表示が古いままになる。

    /// 監視中のデバイスと、解除に必要なブロックを保持する。
    private var masterListeners: [(deviceID: AudioObjectID,
                                   address: AudioObjectPropertyAddress,
                                   block: AudioObjectPropertyListenerBlock)] = []

    private static let masterSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyMute
    ]

    private func installMasterListeners() {
        let deviceID = CoreAudioObject.defaultOutputDeviceID()
        guard deviceID.isValid else { return }

        // デバイスによって通知が来る要素が違う（メイン要素を持たず
        // チャンネル 1/2 側だけで通知するものがある）ため、
        // ワイルドカードに頼らず候補をすべて登録する。重複して呼ばれても
        // 反映処理は冪等なので害はない。
        // ワイルドカードは併用しない。具体要素の登録と二重に一致して
        // 1 回の音量変更で通知が何度も飛んでしまう。
        let elements: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain, 1, 2
        ]
        for selector in Self.masterSelectors {
            for element in elements {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: element
                )
                guard AudioObjectHasProperty(deviceID, &address) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                    self?.onMasterChanged?()
                }
                if AudioObjectAddPropertyListenerBlock(
                    deviceID, &address, DispatchQueue.main, block
                ) == noErr {
                    masterListeners.append((deviceID, address, block))
                }
            }
        }
    }

    private func removeMasterListeners() {
        for var listener in masterListeners {
            AudioObjectRemovePropertyListenerBlock(
                listener.deviceID, &listener.address, DispatchQueue.main, listener.block
            )
        }
        masterListeners.removeAll()
    }

    /// 既定出力デバイスが変わったら、監視対象も張り替える。
    private func reinstallMasterListeners() {
        removeMasterListeners()
        installMasterListeners()
    }

    // MARK: - Process list listener
    //
    // ポップオーバーを開いていない間にアプリが再起動したり、ブラウザが新しい
    // 音声ヘルパーを作ったりしても追従できるようにする。これが無いと、
    // 次にポップオーバーを開くまで新しい音声が全音量で鳴り続ける。

    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var processListBlock: AudioObjectPropertyListenerBlock?

    private func installProcessListListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onProcessListChanged?()
        }
        if AudioObjectAddPropertyListenerBlock(
            .system, &processListAddress, DispatchQueue.main, block
        ) == noErr {
            processListBlock = block
        }
    }

    // MARK: - Device list listener
    //
    // 振り分け先のデバイスが引き抜かれたことを知る唯一の手段。
    // これが無いと、そのアプリはタップされたまま音の出口を失い無音になる。

    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceListBlock: AudioObjectPropertyListenerBlock?

    private func installDeviceListListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.refreshLiveDeviceUIDs()
            self.onDeviceListChanged?()
        }
        if AudioObjectAddPropertyListenerBlock(
            .system, &deviceListAddress, DispatchQueue.main, block
        ) == noErr {
            deviceListBlock = block
        }
    }

    private func removeDeviceListListener() {
        guard let block = deviceListBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            .system, &deviceListAddress, DispatchQueue.main, block
        )
        deviceListBlock = nil
    }

    private func removeProcessListListener() {
        guard let block = processListBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            .system, &processListAddress, DispatchQueue.main, block
        )
        processListBlock = nil
    }
}
