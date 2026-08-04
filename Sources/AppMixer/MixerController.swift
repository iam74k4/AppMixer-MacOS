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

    init() {
        installDefaultDeviceListener()
    }

    deinit {
        removeDefaultDeviceListener()
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

    /// 消えたアプリのタップを掃除。
    func prune(aliveIDs: Set<String>) {
        for id in taps.keys where !aliveIDs.contains(id) {
            taps[id]?.invalidate()
            taps.removeValue(forKey: id)
        }
    }

    private func apply(_ state: State, for app: AudioApp) {
        let gain = state.effectiveGain

        if gain >= 0.999 {
            taps[app.id]?.invalidate()
            taps.removeValue(forKey: app.id)
            return
        }

        if let tap = taps[app.id] {
            tap.gain = gain
            return
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
}
