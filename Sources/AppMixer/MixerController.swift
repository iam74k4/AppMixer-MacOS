import AppKit
import CoreAudio

// アプリ別音量の状態管理とタップの生成/破棄を統括する。
//
// ポリシー:
//   - 実効ゲイン(effectiveGain) = muted ? 0 : volume
//   - 実効ゲインが ~1.0 のときはタップを張らず、アプリを通常経路で再生させる（低負荷）
//   - それ以外はタップを起動し gain を反映
//   - 既定出力デバイスが変わったら、生きているタップを作り直す

@available(macOS 14.2, *)
final class MixerController {

    struct State {
        var volume: Float = 1.0     // 0.0...1.0（スライダー値）
        var muted: Bool = false
        var effectiveGain: Float { muted ? 0.0 : volume }
    }

    private(set) var states: [pid_t: State] = [:]
    private var taps: [pid_t: ProcessTap] = [:]
    private var deviceListenerInstalled = false

    init() {
        installDefaultDeviceListener()
    }

    deinit {
        removeDefaultDeviceListener()
        invalidateAllTaps()
    }

    // MARK: - Public API (main thread)

    func state(for process: AudioProcess) -> State {
        states[process.pid] ?? State()
    }

    func setVolume(_ volume: Float, for process: AudioProcess) {
        var s = states[process.pid] ?? State()
        s.volume = max(0.0, min(1.0, volume))
        states[process.pid] = s
        apply(s, for: process)
    }

    func setMuted(_ muted: Bool, for process: AudioProcess) {
        var s = states[process.pid] ?? State()
        s.muted = muted
        states[process.pid] = s
        apply(s, for: process)
    }

    func reset(for process: AudioProcess) {
        states[process.pid] = State()
        taps[process.pid]?.invalidate()
        taps.removeValue(forKey: process.pid)
    }

    /// 終了しているプロセスのタップを掃除する。
    func pruneTerminatedProcesses(alive: Set<pid_t>) {
        for pid in taps.keys where !alive.contains(pid) {
            taps[pid]?.invalidate()
            taps.removeValue(forKey: pid)
        }
    }

    // MARK: - Apply

    private func apply(_ state: State, for process: AudioProcess) {
        let gain = state.effectiveGain

        // 原音（100%）かつ非ミュートならタップ不要 → 破棄して通常再生に戻す
        if gain >= 0.999 {
            taps[process.pid]?.invalidate()
            taps.removeValue(forKey: process.pid)
            return
        }

        if let tap = taps[process.pid] {
            tap.gain = gain
            return
        }

        // 新規タップ
        let tap = ProcessTap(processObjectID: process.id)
        tap.gain = gain
        do {
            try tap.activate()
            taps[process.pid] = tap
        } catch {
            NSLog("[AppMixer] Failed to activate tap for \(process.name): \(error)")
        }
    }

    private func invalidateAllTaps() {
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }

    // MARK: - Default output device change

    private func rebuildActiveTaps() {
        // 既定出力が変わったら、生きているタップを同じゲインで作り直す。
        let snapshot = taps
        for (pid, oldTap) in snapshot {
            let gain = oldTap.gain
            let processObjectID = oldTap.processObjectID
            oldTap.invalidate()
            let newTap = ProcessTap(processObjectID: processObjectID)
            newTap.gain = gain
            do {
                try newTap.activate()
                taps[pid] = newTap
            } catch {
                NSLog("[AppMixer] Rebuild tap failed (pid \(pid)): \(error)")
                taps.removeValue(forKey: pid)
            }
        }
    }

    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    // 解除時に同一ブロックを渡す必要があるため保持する。
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?

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
