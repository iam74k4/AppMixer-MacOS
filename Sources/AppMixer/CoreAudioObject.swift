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
    ///
    /// `T` には数値か C 構造体だけを渡すこと。HAL は渡した領域へ生バイトを
    /// 書き込むため、オブジェクト参照を含む型を渡すと ARC を迂回して
    /// 参照カウントが壊れる。CFString を読むときは `readString` を使う。
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
        // &value をそのまま渡すと「T がオブジェクト参照を含むかもしれない」と
        // 警告される。ここは生バイトを受け取る場所だと明示して黙らせる。
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID, &address, 0, nil, &dataSize, UnsafeMutableRawPointer(pointer)
            )
        }
        guard status == noErr else { return defaultValue }
        return value
    }

    /// スカラー値を読み、失敗を nil として区別できる形で返す。
    /// `read` は失敗時に既定値を返すため、「読めなかった」のか
    /// 「本当にその値だった」のかが分からない。判定に使う値はこちらで読む。
    ///
    /// `read` と同じく、`T` は数値か C 構造体に限る。
    static func readChecked<T>(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) -> T? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = defaultValue
        var dataSize = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID, &address, 0, nil, &dataSize, UnsafeMutableRawPointer(pointer)
            )
        }
        guard status == noErr else { return nil }
        return value
    }

    /// デバイスの出力ストリームの実フォーマット。
    /// フォーマットはストリームのプロパティなので、デバイスに直接聞いても
    /// 取得できない。まず出力ストリームを引いてから、そこに問い合わせる。
    static func outputStreamFormat(_ deviceID: AudioObjectID) -> AudioStreamBasicDescription? {
        let streams = readArray(deviceID, selector: kAudioDevicePropertyStreams,
                                scope: kAudioObjectPropertyScopeOutput)
        guard let stream = streams.first else { return nil }
        return readChecked(stream, selector: kAudioStreamPropertyVirtualFormat,
                           defaultValue: AudioStreamBasicDescription())
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
    ///
    /// HAL は保持済み（+1）の CFString を書き込んでくる。`CFString?` の変数へ
    /// 直接書かせると ARC の管理外で参照カウントが動くため、`Unmanaged` で
    /// 受けて `takeRetainedValue()` で所有権を引き取る。
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
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
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
        // 実際に書き込まれた長さは dataSize に返る。大きさを聞いてから読むまでの
        // 間に一覧が縮むことがあり、切り詰めないと末尾に .unknown が並んだ配列を
        // 返してしまう。呼び出し側がそれをそのままタップ対象にすると厄介なので、
        // ここで正しい長さにする。
        let written = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard written < count else { return ids }
        return Array(ids.prefix(written))
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

    /// システムの既定出力デバイスを切り替える。
    @discardableResult
    static func setDefaultOutputDevice(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value = deviceID
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        return AudioObjectSetPropertyData(.system, &address, 0, nil, size, &value) == noErr
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
