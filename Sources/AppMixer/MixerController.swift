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
        var effectiveGain: Float { muted ? 0.0 : volume }
    }

    private(set) var states: [String: State] = [:]
    private var taps: [String: ProcessTap] = [:]
    /// 破棄に失敗し、再試行が必要なタップ。放置すると対象アプリが無音のままになる。
    private var pendingTeardown: [ProcessTap] = []
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
            // 設定を変えていないアプリにタップは要らない。
            guard let state = states[app.id], state.effectiveGain < 0.999 else { continue }
            apply(state, for: app)
        }
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
        let gain = state.effectiveGain

        if let tap = taps[app.id] {
            // 同じアプリでも、再起動や新しい音声ヘルパー（ブラウザの新規タブ等）で
            // プロセスオブジェクトが入れ替わる。その場合は張り直さないと、
            // 死んだ ID をタップしたままになり新しい音声に効かなくなる。
            // 列挙順は保証されないため集合で比較する。
            if Set(tap.processObjectIDs) == Set(app.processObjectIDs) {
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

        // タップが無く、原音のままでよいなら何もしない。
        if gain >= 0.999 { return true }

        guard let tap = makeTap(for: app, gain: gain) else { return false }
        taps[app.id] = tap
        return true
    }

    private func makeTap(for app: AudioApp, gain: Float) -> ProcessTap? {
        let tap = ProcessTap(processObjectIDs: app.processObjectIDs)
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
            let newTap = ProcessTap(processObjectIDs: oldTap.processObjectIDs)
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
        let elements: [AudioObjectPropertyElement] = [
            kAudioObjectPropertyElementMain, 1, 2, kAudioObjectPropertyElementWildcard
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
