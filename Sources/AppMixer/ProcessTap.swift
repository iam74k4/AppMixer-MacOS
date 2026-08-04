import Foundation
import CoreAudio
import Accelerate

// 1 プロセスに対する Process Tap。
//
// 構成（Pattern A）:
//   - CATapDescription(stereoMixdownOfProcesses:) + muteBehavior = .mutedWhenTapped
//     → 対象アプリの音は通常の出力経路から消える（二重再生を防ぐ）
//   - プライベート集約デバイス = 既定出力デバイス(サブデバイス) + このタップ(サブタップ)
//   - 単一 IOProc が「タップ入力 × ゲイン」を出力デバイスへ書き込む
//
// gain は UI スレッドから書き換え、IOProc（オーディオスレッド）から読む。
// Float の整列済み読み書きはティアリングしないため、MVP では単純変数で扱う。

@available(macOS 14.2, *)
final class ProcessTap {

    enum TapError: Error, CustomStringConvertible {
        case tapCreationFailed(OSStatus)
        case noOutputDevice
        case aggregateCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case startFailed(OSStatus)

        var description: String {
            switch self {
            case .tapCreationFailed(let s):       return "AudioHardwareCreateProcessTap failed (\(s))"
            case .noOutputDevice:                 return "No default output device / UID"
            case .aggregateCreationFailed(let s): return "AudioHardwareCreateAggregateDevice failed (\(s))"
            case .ioProcCreationFailed(let s):    return "AudioDeviceCreateIOProcIDWithBlock failed (\(s))"
            case .startFailed(let s):             return "AudioDeviceStart failed (\(s))"
            }
        }
    }

    let processObjectID: AudioObjectID

    /// 0.0（無音）〜 1.0（原音）。1.0 超で増幅も可能だがクリップ注意。
    var gain: Float = 1.0

    private var tapID: AudioObjectID = .unknown
    private var aggregateID: AudioObjectID = .unknown
    private var deviceProcID: AudioDeviceIOProcID?
    private var streamDescription = AudioStreamBasicDescription()
    private let ioQueue = DispatchQueue(label: "com.appmixer.ioproc")

    init(processObjectID: AudioObjectID) {
        self.processObjectID = processObjectID
    }

    deinit { invalidate() }

    // MARK: - Lifecycle

    func activate() throws {
        // 1) タップ生成
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.uuid = UUID()
        tapDescription.muteBehavior = .mutedWhenTapped
        tapDescription.isPrivate = true

        var newTapID: AudioObjectID = .unknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID.isValid else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        tapID = newTapID

        // タップのフォーマット（ログ/将来のフォーマット整合用）
        streamDescription = CoreAudioObject.read(
            tapID, selector: kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription()
        )

        // 2) 既定出力デバイスの UID
        let outputDeviceID = CoreAudioObject.defaultOutputDeviceID()
        guard outputDeviceID.isValid, let outputUID = CoreAudioObject.deviceUID(outputDeviceID) else {
            invalidate()
            throw TapError.noOutputDevice
        }

        // 3) プライベート集約デバイス（出力デバイス + タップ）
        let aggregateUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "AppMixer-Tap-\(processObjectID)",
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
        guard aggStatus == noErr, newAggregateID.isValid else {
            invalidate()
            throw TapError.aggregateCreationFailed(aggStatus)
        }
        aggregateID = newAggregateID

        // 4) IOProc: タップ入力 × ゲイン → 出力
        var procID: AudioDeviceIOProcID?
        let ioBlock: AudioDeviceIOBlock = { [weak self] _, inInputData, _, outOutputData, _ in
            self?.render(input: inInputData, output: outOutputData)
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

    func invalidate() {
        if let procID = deviceProcID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        deviceProcID = nil

        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        if tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = .unknown
        }
    }

    // MARK: - Realtime render (audio thread)

    private func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        var g = gain
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)

        let pairCount = min(inBuffers.count, outBuffers.count)
        for i in 0..<pairCount {
            let inBuffer = inBuffers[i]
            let outBuffer = outBuffers[i]
            guard let inData = inBuffer.mData, let outData = outBuffer.mData else { continue }

            let byteCount = min(inBuffer.mDataByteSize, outBuffer.mDataByteSize)
            let floatCount = Int(byteCount) / MemoryLayout<Float>.size

            if g == 1.0 {
                memcpy(outData, inData, Int(byteCount))
            } else {
                let inPtr = inData.assumingMemoryBound(to: Float.self)
                let outPtr = outData.assumingMemoryBound(to: Float.self)
                vDSP_vsmul(inPtr, 1, &g, outPtr, 1, vDSP_Length(floatCount))
            }
        }

        // 入力より出力バッファが多い場合は残りを無音化
        if outBuffers.count > pairCount {
            for i in pairCount..<outBuffers.count {
                if let outData = outBuffers[i].mData {
                    memset(outData, 0, Int(outBuffers[i].mDataByteSize))
                }
            }
        }
    }
}
