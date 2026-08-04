import Foundation
import CoreAudio
import Accelerate

// 1 アプリ（複数の音声プロセスを含む）に対する Process Tap。
//
// 構成（Pattern A）:
//   - CATapDescription(stereoMixdownOfProcesses: [全プロセス]) + .mutedWhenTapped
//     → 対象アプリの音は通常経路から消える（二重再生防止）
//   - プライベート集約デバイス = 既定出力デバイス + このタップ
//   - 単一 IOProc が「タップ入力 × ゲイン」を出力へ書き込み、同時にピークを計測
//
// gain は UI スレッドから書き換え、IOProc（オーディオスレッド）から読む。
// level（0...1 の直近ピーク）は IOProc が書き、UI から読む（メーター用）。

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

    let processObjectIDs: [AudioObjectID]

    /// 0.0（無音）〜 1.0（原音）。UI から設定、IOProc が参照。
    var gain: Float = 1.0

    /// 直近のピーク（0...1）。IOProc が更新、UI が参照（メーター）。
    private(set) var level: Float = 0

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
        guard aggStatus == noErr, newAggregateID.isValid else {
            invalidate()
            throw TapError.aggregateCreationFailed(aggStatus)
        }
        aggregateID = newAggregateID

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
        level = 0
    }

    // MARK: - Realtime render (audio thread)

    private func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        var g = gain
        let inBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outBuffers = UnsafeMutableAudioBufferListPointer(output)

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

            // ピーク（入力の絶対値最大）を計測
            var localPeak: Float = 0
            vDSP_maxmgv(inPtr, 1, &localPeak, vDSP_Length(floatCount))
            peak = max(peak, localPeak)

            if g == 1.0 {
                memcpy(outData, inData, Int(byteCount))
            } else {
                vDSP_vsmul(inPtr, 1, &g, outPtr, 1, vDSP_Length(floatCount))
            }
        }

        // 出力バッファが余る場合は無音化
        if outBuffers.count > pairCount {
            for i in pairCount..<outBuffers.count {
                if let outData = outBuffers[i].mData {
                    memset(outData, 0, Int(outBuffers[i].mDataByteSize))
                }
            }
        }

        // 減衰付きピークホールド（実効ゲインを反映して表示）
        let displayPeak = min(1.0, peak * g)
        level = max(displayPeak, level * 0.82)
    }
}
