import Foundation
import CoreAudio
import Accelerate

/// IOProc（オーディオスレッド）と UI スレッドで共有する状態。
///
/// IOProc から `weak self` を辿ると弱参照ロードでロック/retain が走り
/// リアルタイム安全ではないため、値だけを持つ箱を強参照でキャプチャする。
final class TapState {
    /// UI が書き、IOProc が読む（0.0...1.0）。
    var gain: Float = 1.0
    /// IOProc が書き、UI が読む（直近ピーク 0...1）。
    var level: Float = 0
}

// 1 アプリ（複数の音声プロセスを含む）に対する Process Tap。
//
// 構成（Pattern A）:
//   - CATapDescription(stereoMixdownOfProcesses: [全プロセス]) + .mutedWhenTapped
//     → 対象アプリの音は通常経路から消える（二重再生防止）
//   - プライベート集約デバイス = 既定出力デバイス + このタップ
//   - 単一 IOProc が「タップ入力 × ゲイン」を出力へ書き込み、同時にピークを計測

final class ProcessTap {

    enum TapError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case noOutputDevice
        case unsupportedFormat(AudioStreamBasicDescription)
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):       return "AudioHardwareCreateProcessTap failed (\(s))"
            case .noOutputDevice:                 return "No default output device / UID"
            case .unsupportedFormat(let f):
                return "Unsupported tap format (flags: \(f.mFormatFlags), ch: \(f.mChannelsPerFrame))"
            case .aggregateCreationFailed(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .ioProcCreationFailed(let s):    return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .startFailed(let s):             return "AudioDeviceStart failed (\(s))"
            }
        }
    }

    let processObjectIDs: [AudioObjectID]

    /// IOProc と共有する状態（ゲイン / メーター）。
    let state = TapState()

    /// 0.0（無音）〜 1.0（原音）。
    var gain: Float {
        get { state.gain }
        set { state.gain = newValue }
    }

    /// 直近のピーク（0...1）。メーター表示用。
    var level: Float { state.level }

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "com.appmixer.ioproc")

    init(processObjectIDs: [AudioObjectID]) {
        self.processObjectIDs = processObjectIDs
    }

    deinit { invalidate() }

    // MARK: - Lifecycle

    func activate() throws {
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true

        var newTapID: AudioObjectID = .unknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID.isValid else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        // レンダリングは 32bit float 前提のため、フォーマットを検証してから進む。
        let format: AudioStreamBasicDescription = CoreAudioObject.read(
            tapID, selector: kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription()
        )
        guard format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            invalidate()
            throw TapError.unsupportedFormat(format)
        }

        let outputDeviceID = CoreAudioObject.defaultOutputDeviceID()
        guard outputDeviceID.isValid, let outputUID = CoreAudioObject.deviceUID(outputDeviceID) else {
            invalidate()
            throw TapError.noOutputDevice
        }

        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppMixer-\(aggregateUID.prefix(8))",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [ kAudioSubDeviceUIDKey: outputUID ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString
                ]
            ]
        ]

        var newAggregateID: AudioObjectID = .unknown
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        // 生成されたデバイスを取りこぼさないよう、guard の前に保持する
        // （noErr でも ID が無効なケースで invalidate() が後始末できるように）。
        aggregateID = newAggregateID
        guard aggStatus == noErr, newAggregateID.isValid else {
            invalidate()
            throw TapError.aggregateCreationFailed(aggStatus)
        }

        // 出力側のフォーマットがタップと一致しない場合、単純なバッファコピーでは
        // 早回し再生やノイズになる。取り違えた音を出すより起動を諦める。
        let outFormat: AudioStreamBasicDescription = CoreAudioObject.read(
            aggregateID,
            selector: kAudioStreamPropertyVirtualFormat,
            scope: kAudioObjectPropertyScopeOutput,
            defaultValue: AudioStreamBasicDescription()
        )
        if outFormat.mChannelsPerFrame != 0 {
            let interleavedFlag = kAudioFormatFlagIsNonInterleaved
            guard outFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                  outFormat.mBitsPerChannel == 32,
                  outFormat.mChannelsPerFrame == format.mChannelsPerFrame,
                  (outFormat.mFormatFlags & interleavedFlag)
                    == (format.mFormatFlags & interleavedFlag) else {
                invalidate()
                throw TapError.unsupportedFormat(outFormat)
            }
        }

        // 箱を強参照でキャプチャし、IOProc 内で self に触れないようにする。
        let state = self.state
        var procID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            ProcessTap.render(input: inInputData, output: outOutputData, state: state)
        }
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue, ioBlock)
        guard procStatus == noErr, let procID else {
            invalidate()
            throw TapError.ioProcCreationFailed(procStatus)
        }
        deviceProcID = procID

        let startStatus = AudioDeviceStart(aggregateID, procID)
        guard startStatus == noErr else {
            invalidate()
            throw TapError.startFailed(startStatus)
        }
    }

    /// タップと集約デバイスを完全に破棄できたか。
    /// false のままだと対象アプリは .mutedWhenTapped のまま無音になるため、
    /// 呼び出し側は破棄が終わるまで解放せずに再試行する。
    var isFullyTornDown: Bool { !tapID.isValid && !aggregateID.isValid }

    /// タップを破棄して対象アプリの音声を通常経路へ戻す。
    /// デバイス切替中などで HAL が破棄に失敗することがあるため、
    /// 失敗した ID は保持し、次回の呼び出しで再試行できるようにする。
    func invalidate() {
        if let procID = deviceProcID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            deviceProcID = nil
        }

        if aggregateID.isValid {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status == noErr {
                aggregateID = .unknown
            } else {
                NSLog("[AppMixer] DestroyAggregateDevice failed (\(status)); will retry")
            }
        }
        if tapID.isValid {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr {
                tapID = .unknown
            } else {
                NSLog("[AppMixer] DestroyProcessTap failed (\(status)); will retry")
            }
        }
        state.level = 0
    }

    // MARK: - Realtime render (audio thread)

    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        state: TapState
    ) {
        var g = state.gain
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)

        // 先に出力を無音化しておく。書き込まなかった領域に前サイクルの
        // 音が残って繰り返しノイズになるのを防ぐ。
        for i in 0..<outBuffers.count {
            if let outData = outBuffers[i].mData {
                memset(outData, 0, Int(outBuffers[i].mDataByteSize))
            }
        }

        var peak: Float = 0
        let pairCount = min(inBuffers.count, outBuffers.count)

        for i in 0..<pairCount {
            let inBuffer = inBuffers[i]
            let outBuffer = outBuffers[i]
            guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }

            let byteCount = min(inBuffer.mDataByteSize, outBuffer.mDataByteSize)
            let floatCount = Int(byteCount) / MemoryLayout<Float>.size
            let inPtr = inData.assumingMemoryBound(to: Float.self)
            let outPtr = outData.assumingMemoryBound(to: Float.self)

            var localPeak: Float = 0
            vDSP_maxmgv(inPtr, 1, &localPeak, vDSP_Length(floatCount))
            peak = max(peak, localPeak)

            if g == 1.0 {
                memcpy(outData, inData, Int(byteCount))
            } else {
                vDSP_vsmul(inPtr, 1, &g, outPtr, 1, vDSP_Length(floatCount))
            }
        }

        // 減衰付きピークホールド（実効ゲインを反映して表示）
        let displayPeak = min(1.0, peak * g)
        state.level = max(displayPeak, state.level * 0.82)
    }
}
