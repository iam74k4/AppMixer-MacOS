import AppKit
import CoreAudio

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
    /// メーター用タップを 1 つずつ解放している最中か。
    private var draining = false
    private var deviceListenerInstalled = false
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// マスター音量/ミュートが外部（F11/F12 やシステム設定）で変わったときに呼ばれる。
    var onMasterChanged: (() -> Void)?

    /// 音声プロセスの増減（アプリ起動/終了、ブラウザの新規タブ等）を検知したときに呼ばれる。
    var onProcessListChanged: (() -> Void)?

    init() {
        installDefaultDeviceListener()
        installMasterListeners()
        installProcessListListener()
    }

    deinit {
        removeDefaultDeviceListener()
        removeMasterListeners()
        removeProcessListListener()
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
        var s = states[app.id] ?? State()
        s.outputDeviceUID = uid
        states[app.id] = s

        // 既定出力へ戻した上に音量も原音なら、タップは不要なので畳む。
        if !s.isCustomized, taps[app.id] != nil, duckMultiplier >= 1.0 {
            if let tap = taps.removeValue(forKey: app.id) {
                tap.invalidate()
                retireIfNeeded(tap)
            }
            return true
        }
        return apply(s, for: app)
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

        for app in apps {
            let state = states[app.id] ?? State()
            let beingDucked = duckMultiplier < 1.0 && !duckExcludedIDs.contains(app.id)

            if beingDucked && app.isRunningOutput {
                // 絞るにはタップが要る。ゲインの適用は IOProc 側でフェードする。
                apply(state, for: app)
            } else if let tap = taps[app.id] {
                // 解除。設定が無ければ後で解放されるが、まず音量を戻す。
                tap.gain = targetGain(for: app.id)
            }
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
    }

    /// 現在のアプリ一覧に合わせてタップを同期する。
    /// プロセスオブジェクトが入れ替わったアプリはタップを張り直す。
    func syncTaps(with apps: [AudioApp]) {
        for app in apps {
            // 設定も無くダッキング対象でもないアプリにタップは要らない。
            let state = states[app.id] ?? State()
            let beingDucked = duckMultiplier < 1.0
                && !duckExcludedIDs.contains(app.id) && app.isRunningOutput
            guard state.isCustomized || beingDucked else { continue }
            apply(state, for: app)
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
            if Set(tap.processObjectIDs) == Set(app.processObjectIDs),
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
                return true
            }
            // 張り替えに失敗したら、古いタップを残す方が安全（設定を失わない）。
            NSLog("[AppMixer] Keeping previous tap for \(app.name); rebuild failed")
            return false
        }

        // タップが無く、原音のまま既定出力でよいなら何もしない。
        if gain >= 0.999 && state.outputDeviceUID == nil { return true }

        guard let tap = makeTap(for: app, gain: gain) else { return false }
        taps[app.id] = tap
        return true
    }

    /// 現在の設定に一致するタップが張られているか。
    /// 古い（ヘルパーや出力先が変わった）タップは「無し」と同じ扱いにする。
    func hasFreshTap(for app: AudioApp) -> Bool {
        guard let tap = taps[app.id] else { return false }
        return Set(tap.processObjectIDs) == Set(app.processObjectIDs)
            && tap.outputDeviceUID == (states[app.id] ?? State()).outputDeviceUID
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
            return true
        }

        guard let tap = makeTap(for: app, gain: gain) else { return false }
        taps[app.id] = tap
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
            NSLog("[AppMixer] Failed to activate tap for \(app.name): \(error)")
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

    var masterMuteSupported: Bool {
        CoreAudioObject.outputMuteSupported(CoreAudioObject.defaultOutputDeviceID())
    }

    func masterVolume() -> Float {
        CoreAudioObject.outputVolume(CoreAudioObject.defaultOutputDeviceID()) ?? 1.0
    }

    func masterMuted() -> Bool {
        CoreAudioObject.outputMuted(CoreAudioObject.defaultOutputDeviceID())
    }

    @discardableResult
    func setMasterVolume(_ volume: Float) -> Bool {
        CoreAudioObject.setOutputVolume(CoreAudioObject.defaultOutputDeviceID(), volume)
    }

    @discardableResult
    func setMasterMuted(_ muted: Bool) -> Bool {
        CoreAudioObject.setOutputMuted(CoreAudioObject.defaultOutputDeviceID(), muted)
    }

    func defaultOutputName() -> String {
        CoreAudioObject.deviceName(CoreAudioObject.defaultOutputDeviceID()) ?? "不明な出力デバイス"
    }

    // MARK: - Default output device change

    private func rebuildActiveTaps() {
        // 出力先が変わったので、マスター音量の監視対象も新しいデバイスへ移す。
        reinstallMasterListeners()
        onMasterChanged?()

        retryPendingTeardown()

        let snapshot = taps
        for (id, oldTap) in snapshot {
            // 出力先を明示しているタップは既定出力の変更と無関係。
            guard oldTap.followsDefaultOutput else { continue }
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
            } catch {
                // 失敗時は古いタップを残す。破棄してしまうと設定が失われ、
                // ミュート中のアプリが突然鳴り出す。
                NSLog("[AppMixer] Rebuild tap failed (\(id)): \(error)")
            }
        }
    }

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private func installDefaultDeviceListener() {
        guard !deviceListenerInstalled else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildActiveTaps()
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

    private func removeProcessListListener() {
        guard let block = processListBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            .system, &processListAddress, DispatchQueue.main, block
        )
        processListBlock = nil
    }
}
