import Foundation
import CoreAudio

// 出力デバイスの列挙（アプリ別ルーティングの選択肢）。

struct AudioDevice: Identifiable, Equatable {
    let id: AudioObjectID
    let uid: String
    let name: String
}

enum AudioDeviceEnumerator {

    /// 出力可能なデバイスを列挙する。
    /// AppMixer 自身が作ったプライベート集約デバイスは除外する。
    static func outputDevices() -> [AudioDevice] {
        let deviceIDs = CoreAudioObject.readArray(.system, selector: kAudioHardwarePropertyDevices)
        var devices: [AudioDevice] = []

        for deviceID in deviceIDs {
            guard hasOutputStreams(deviceID) else { continue }
            guard let uid = CoreAudioObject.deviceUID(deviceID),
                  let name = CoreAudioObject.deviceName(deviceID) else { continue }
            // 自前の集約デバイスは選択肢に出さない。
            guard !name.hasPrefix("AppMixer-") else { continue }
            devices.append(AudioDevice(id: deviceID, uid: uid, name: name))
        }

        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// 出力ストリームを持つデバイスか。
    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioBufferList>.size) else { return false }

        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else {
            return false
        }
        let list = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        for buffer in list where buffer.mNumberChannels > 0 { return true }
        return false
    }
}
