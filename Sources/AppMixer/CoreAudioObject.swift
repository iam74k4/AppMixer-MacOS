import Foundation
import CoreAudio

// Core Audio の AudioObjectID プロパティ読み取りヘルパー群。
// AudioCap (insidegui/AudioCap) の CoreAudioUtils.swift を参考にした最小実装。

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
    static let system = AudioObjectID(kAudioObjectSystemObject)

    var isValid: Bool { self != .unknown }
}

enum CoreAudioObject {

    // MARK: - 汎用リード

    /// スカラー値（AudioObjectID / pid_t / UInt32 / AudioStreamBasicDescription 等）を読む。
    static func read<T>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) -> T {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var dataSize = UInt32(MemoryLayout<T>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr else { return defaultValue }
        return value
    }

    /// CFString プロパティを String として読む。
    static func readString(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString? = nil
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, let value else { return nil }
        return value as String
    }

    /// AudioObjectID 配列を読む（プロセス一覧など）。
    static func readArray(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: .unknown, count: count)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &ids)
        guard status == noErr else { return [] }
        return ids
    }

    // MARK: - 便利メソッド

    /// pid からプロセス AudioObjectID へ変換（qualifier として pid を渡す）。
    @available(macOS 14.2, *)
    static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pidValue = pid
        var objectID: AudioObjectID = .unknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { qualifier in
            AudioObjectGetPropertyData(
                .system, &address,
                UInt32(MemoryLayout<pid_t>.size), qualifier,
                &dataSize, &objectID
            )
        }
        guard status == noErr else { return .unknown }
        return objectID
    }

    /// システムの既定出力デバイス。
    static func defaultOutputDeviceID() -> AudioObjectID {
        read(.system, selector: kAudioHardwarePropertyDefaultOutputDevice, defaultValue: AudioObjectID.unknown)
    }

    /// デバイスの UID 文字列。
    static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        readString(deviceID, selector: kAudioDevicePropertyDeviceUID)
    }

    /// デバイス名。
    static func deviceName(_ deviceID: AudioObjectID) -> String? {
        readString(deviceID, selector: kAudioDevicePropertyDeviceNameCFString)
    }
}
