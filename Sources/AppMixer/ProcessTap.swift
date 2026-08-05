import Foundation
import CoreAudio
import Accelerate
import os

/// IOProc（オーディオスレッド）と UI スレッドで共有する状態。
///
/// IOProc から `weak self` を辿ると弱参照ロードでロック/retain が走り
/// リアルタイム安全ではないため、値だけを持つ箱を強参照でキャプチャする。
final class TapState {
    /// UI が書き、IOProc が目標として読む（0.0...1.0）。
    var targetGain: Float = 1.0
    /// IOProc が保持する現在のゲイン。目標へ向かって滑らかに動く。
    var currentGain: Float = 1.0
    /// 1 サンプルあたりのゲイン変化量。急変によるプチノイズを防ぐ。
    var rampStep: Float = 1.0 / 2048.0
    /// IOProc が書き、UI が読む（直近ピーク 0...1）。
    var level: Float = 0
}

// 1 アプリ（複数の音声プロセスを含む）に対する Process Tap。
//
// 構成（Pattern A）:
//   - CATapDescription(stereoMixdownOfProcesses: [全プロセス]) + .mutedWhenTapped
//     → 対象アプリの音は通常経路から消える（二重再生防止）
//   - プライベート集約デバイス = 出力デバイス + このタップ
//   - 単一 IOProc が「タップ入力 × ゲイン」を出力へ書き込み、同時にピークを計測
//
// 出力デバイスは既定出力（outputDeviceUID == nil）か、指定したデバイス。
// 指定するとそのアプリだけ別のデバイスから鳴らせる（アプリ別ルーティング）。

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
            case .noOutputDevice:                 return "No output device / UID"
            case .unsupportedFormat(let f):
                return "Unsupported format (flags: \(f.mFormatFlags), ch: \(f.mChannelsPerFrame))"
            case .aggregateCreationFailed(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .ioProcCreationFailed(let s):    return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .startFailed(let s):             return "AudioDeviceStart failed (\(s))"
            }
        }
    }

    /// ゲイン変化にかける時間。短すぎるとプチッと鳴り、長すぎると反応が鈍く感じる。
    private static let rampSeconds = 0.08

    let processObjectIDs: [AudioObjectID]

    /// 出力先デバイスの UID。nil なら既定出力デバイスに追従する。
    let outputDeviceUID: String?

    /// 既定出力デバイスの変更に追従すべきタップか。
    var followsDefaultOutput: Bool { outputDeviceUID == nil }

    /// IOProc と共有する状態（ゲイン / メーター）。
    let state = TapState()

    /// 目標ゲイン（0.0...1.0）。実際の適用は数十 ms かけて滑らかに追従する。
    var gain: Float {
        get { state.targetGain }
        set { state.targetGain = newValue }
    }

    /// 直近のピーク（0...1）。メーター表示用。
    var level: Float { state.level }

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?

    init(processObjectIDs: [AudioObjectID], outputDeviceUID: String? = nil) {
        self.processObjectIDs = processObjectIDs
        self.outputDeviceUID = outputDeviceUID
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

        // フェード時間から 1 スロットあたりの変化量を決める（およそ 80ms）。
        // render はバッファ内の Float を 1 つずつ辿るため、インターリーブ形式では
        // 1 フレームにチャンネル数ぶんのスロットがある。これを勘定に入れないと
        // ステレオでフェードが半分の時間で終わってしまう。
        let sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 48_000
        let isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let slotsPerFrame = isInterleaved ? max(1, Int(format.mChannelsPerFrame)) : 1
        state.rampStep = Float(1.0 / (sampleRate * Self.rampSeconds * Double(slotsPerFrame)))

        // 出力先。指定が無ければ既定出力を使う。
        let outputUID: String
        if let outputDeviceUID {
            outputUID = outputDeviceUID
        } else {
            let deviceID = CoreAudioObject.defaultOutputDeviceID()
            guard deviceID.isValid, let uid = CoreAudioObject.deviceUID(deviceID) else {
                invalidate()
                throw TapError.noOutputDevice
            }
            outputUID = uid
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
        // 生成されたデバイスを取りこぼさないよう、guard の前に保持する。
        aggregateID = newAggregateID
        guard aggStatus == noErr, newAggregateID.isValid else {
            invalidate()
            throw TapError.aggregateCreationFailed(aggStatus)
        }

        // 出力側のフォーマットがタップと一致しない場合、単純なバッファコピーでは
        // 早回し再生やノイズになる。取り違えた音を出すより起動を諦める。
        //
        // フォーマットはデバイスではなく「ストリーム」のプロパティなので、
        // 集約デバイスに直接聞いても取れない。読めなかったときは通すのではなく
        // 諦める（fail closed）。通してしまうと、この検査そのものが素通りする。
        guard let outFormat = CoreAudioObject.outputStreamFormat(aggregateID) else {
            invalidate()
            throw TapError.unsupportedFormat(AudioStreamBasicDescription())
        }
        let interleavedFlag = kAudioFormatFlagIsNonInterleaved
        guard outFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              outFormat.mBitsPerChannel == 32,
              outFormat.mChannelsPerFrame == format.mChannelsPerFrame,
              (outFormat.mFormatFlags & interleavedFlag)
                == (format.mFormatFlags & interleavedFlag) else {
            invalidate()
            throw TapError.unsupportedFormat(outFormat)
        }

        // 箱を強参照でキャプチャし、IOProc 内で self に触れないようにする。
        let state = self.state
        var procID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { _, inInputData, _, outOutputData, _ in
            ProcessTap.render(input: inInputData, output: outOutputData, state: state)
        }
        // キューを渡すと通常優先度のキュー上でレンダリングされ、負荷時に
        // バッファを落とす。nil を渡してデバイスの IO スレッドで動かす。
        // render は確保もロックも行わないためリアルタイムスレッドで安全。
        let procStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil, ioBlock)
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
                AppLog.audio.error("DestroyAggregateDevice failed (\(status, privacy: .public)); will retry")
            }
        }
        if tapID.isValid {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status == noErr {
                tapID = .unknown
            } else {
                AppLog.audio.error("DestroyProcessTap failed (\(status, privacy: .public)); will retry")
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
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)

        // 先に出力を無音化しておく。書き込まなかった領域に前サイクルの
        // 音が残って繰り返しノイズになるのを防ぐ。
        for i in 0..<outBuffers.count {
            if let outData = outBuffers[i].mData {
                memset(outData, 0, Int(outBuffers[i].mDataByteSize))
            }
        }

        let startGain = state.currentGain
        let target = state.targetGain
        let step = state.rampStep
        var endGain = startGain
        var peak: Float = 0
        let pairCount = min(inBuffers.count, outBuffers.count)

        for i in 0..<pairCount {
            let inBuffer = inBuffers[i]
            let outBuffer = outBuffers[i]
            guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }

            let byteCount = min(inBuffer.mDataByteSize, outBuffer.mDataByteSize)
            let count = Int(byteCount) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let inPtr = inData.assumingMemoryBound(to: Float.self)
            let outPtr = outData.assumingMemoryBound(to: Float.self)

            var localPeak: Float = 0
            vDSP_maxmgv(inPtr, 1, &localPeak, vDSP_Length(count))
            peak = max(peak, localPeak)

            if startGain == target {
                if target == 1.0 {
                    memcpy(outData, inData, Int(byteCount))
                } else {
                    var g = target
                    vDSP_vsmul(inPtr, 1, &g, outPtr, 1, vDSP_Length(count))
                }
                endGain = target
            } else {
                // 目標へ向かって 1 サンプルずつ寄せる。急にゲインを変えると
                // 波形が不連続になりプチッと鳴るため、必ず滑らかに変化させる。
                var g = startGain
                if target > startGain {
                    for n in 0..<count {
                        g = min(target, g + step)
                        outPtr[n] = inPtr[n] * g
                    }
                } else {
                    for n in 0..<count {
                        g = max(target, g - step)
                        outPtr[n] = inPtr[n] * g
                    }
                }
                endGain = g
            }
        }

        state.currentGain = endGain

        // 減衰付きピークホールド（実効ゲインを反映して表示）
        let displayPeak = min(1.0, peak * endGain)
        state.level = max(displayPeak, state.level * 0.82)
    }
}
