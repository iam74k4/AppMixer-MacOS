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
    private var deviceListenerInstalled = false
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// マスター音量/ミュートが外部（F11/F12 やシステム設定）で変わったときに呼ばれる。
    var onMasterChanged: (() -> Void)?

    init() {
        installDefaultDeviceListener()
        installMasterListeners()
    }

    deinit {
        removeDefaultDeviceListener()
        removeMasterListeners()
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }

    /// タップ対象アプリの音声は .mutedWhenTapped で通常経路から外れているため、
    /// タップを破棄しない限り無音のままになる。終了時の後始末が必須。

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

    func setVolume(_ volume: Float, for app: AudioApp) {
        var s = states[app.id] ?? State()
        s.volume = max(0.0, min(1.0, volume))
        states[app.id] = s
        apply(s, for: app)
    }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        var s = states[app.id] ?? State()
        s.muted = muted
        states[app.id] = s
        apply(s, for: app)
    }

    /// 永続化した状態を復元する（デフォルトと異なる場合のみタップを張る）。
    func restore(_ state: State, for app: AudioApp) {
        states[app.id] = state
        apply(state, for: app)
    }

    func reset(for app: AudioApp) {
        states[app.id] = State()
        taps[app.id]?.invalidate()
        taps.removeValue(forKey: app.id)
    }

    /// 現在のアプリ一覧に合わせてタップを同期する。
    /// プロセスオブジェクトが入れ替わったアプリはタップを張り直す。
    func syncTaps(with apps: [AudioApp]) {
        for app in apps {
            let state = states[app.id] ?? State()
            guard state.effectiveGain < 0.999 else { continue }
            apply(state, for: app)
        }
    }

    /// 全タップを破棄して、各アプリの音声を通常経路へ戻す。
    /// 終了時に必ず呼ぶこと（呼ばないとアプリが無音のままになりうる）。
    func shutdown() {
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }

    /// 消えたアプリのタップと状態を掃除する。
    /// （音量設定そのものは UserDefaults 側に残るため、再検出時に復元される）
    func prune(aliveIDs: Set<String>) {
        for id in taps.keys where !aliveIDs.contains(id) {
            taps[id]?.invalidate()
            taps.removeValue(forKey: id)
        }
        states = states.filter { aliveIDs.contains($0.key) }
    }

    private func apply(_ state: State, for app: AudioApp) {
        let gain = state.effectiveGain

        if gain >= 0.999 {
            taps[app.id]?.invalidate()
            taps.removeValue(forKey: app.id)
            return
        }

        if let tap = taps[app.id] {
            // 同じアプリでも、再起動や新しい音声ヘルパー（ブラウザの新規タブ等）で
            // プロセスオブジェクトが入れ替わる。その場合は張り直さないと、
            // 死んだ ID をタップしたままになり新しい音声に効かなくなる。
            if tap.processObjectIDs == app.processObjectIDs {
                tap.gain = gain
                return
            }
            tap.invalidate()
            taps.removeValue(forKey: app.id)
        }

        let tap = ProcessTap(processObjectIDs: app.processObjectIDs)
        tap.gain = gain
        do {
            try tap.activate()
            taps[app.id] = tap
        } catch {
            NSLog("[AppMixer] Failed to activate tap for \(app.name): \(error)")
        }
    }

    // MARK: - Master (default output device)

    var masterVolumeSupported: Bool {
        CoreAudioObject.outputVolumeSupported(CoreAudioObject.defaultOutputDeviceID())
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

        let snapshot = taps
        for (id, oldTap) in snapshot {
            let gain = oldTap.gain
            let objectIDs = oldTap.processObjectIDs
            oldTap.invalidate()
            let newTap = ProcessTap(processObjectIDs: objectIDs)
            newTap.gain = gain
            do {
                try newTap.activate()
                taps[id] = newTap
            } catch {
                NSLog("[AppMixer] Rebuild tap failed (\(id)): \(error)")
                taps.removeValue(forKey: id)
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

        for selector in Self.masterSelectors {
            // 要素はワイルドカードにする。デバイスによってはメイン要素ではなく
            // チャンネル 1/2 側で音量変更が通知されるため。
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: kAudioObjectPropertyElementWildcard
            )
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
}
