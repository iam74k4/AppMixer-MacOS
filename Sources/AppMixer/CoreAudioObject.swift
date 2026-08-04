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

    /// プロパティが存在するか。
    static func hasProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(objectID, &address)
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

    // MARK: - マスター音量 / ミュート（既定出力デバイス）

    /// 既定出力デバイスの音量（0...1）。取得不可なら nil。
    static func outputVolume(_ deviceID: AudioObjectID) -> Float? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
            return value
        }
        // メイン要素が無いデバイスはチャンネル1を代表値にする
        address.mElement = 1
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
            return value
        }
        return nil
    }

    /// 既定出力デバイスの音量を設定（0...1）。成功で true。
    @discardableResult
    static func setOutputVolume(_ deviceID: AudioObjectID, _ volume: Float) -> Bool {
        var value = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)

        // まずメイン要素、駄目ならチャンネル1/2に個別設定
        let elements: [AudioObjectPropertyElement] = [kAudioObjectPropertyElementMain, 1, 2]
        var didSet = false
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var settable: DarwinBoolean = false
            if AudioObjectHasProperty(deviceID, &address),
               AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
               settable.boolValue,
               AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr {
                didSet = true
                if element == kAudioObjectPropertyElementMain { break }
            }
        }
        return didSet
    }

    /// 既定出力デバイスがミュートされているか。
    static func outputMuted(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr {
            return value != 0
        }
        return false
    }

    /// 既定出力デバイスのミュートを設定。成功で true。
    @discardableResult
    static func setOutputMuted(_ deviceID: AudioObjectID, _ muted: Bool) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
           settable.boolValue {
            return AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &value) == noErr
        }
        return false
    }

    /// 既定出力デバイスがマスター音量制御に対応しているか。
    static func outputVolumeSupported(_ deviceID: AudioObjectID) -> Bool {
        settable(deviceID, selector: kAudioDevicePropertyVolumeScalar,
                 elements: [kAudioObjectPropertyElementMain, 1])
    }

    /// 既定出力デバイスがミュート制御に対応しているか。
    /// 音量が設定できてもミュートは持たないデバイスがあるため、別に判定する。
    static func outputMuteSupported(_ deviceID: AudioObjectID) -> Bool {
        settable(deviceID, selector: kAudioDevicePropertyMute,
                 elements: [kAudioObjectPropertyElementMain])
    }

    /// いずれかの要素で書き込み可能なプロパティかどうか。
    private static func settable(
        _ deviceID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        elements: [AudioObjectPropertyElement]
    ) -> Bool {
        for element in elements {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeOutput,
                mElement: element
            )
            var isSettable: DarwinBoolean = false
            if AudioObjectHasProperty(deviceID, &address),
               AudioObjectIsPropertySettable(deviceID, &address, &isSettable) == noErr,
               isSettable.boolValue {
                return true
            }
        }
        return false
    }
}
