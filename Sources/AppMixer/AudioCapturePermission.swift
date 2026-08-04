import Foundation

// システム音声録音（Process Tap）の TCC 権限。
// サービス文字列は kTCCServiceAudioCapture（マイクではない）。
// TCC.framework のプライベート SPI を dlopen して状態確認/要求する。
// SPI が使えない場合でも、最初の AudioHardwareCreateProcessTap で
// 暗黙的に許可プロンプトが出るため、フォールバックとして .notDetermined を返す。

enum AudioCapturePermission {

    enum Status: Equatable {
        case authorized
        case denied
        case notDetermined
    }

    private static let serviceName = "kTCCServiceAudioCapture" as CFString
    private static let tccPath =
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"

    // TCCAccessPreflight(CFStringRef service, CFDictionaryRef options) -> int
    private typealias PreflightFunc = @convention(c) (CFString, CFDictionary?) -> Int
    // TCCAccessRequest(CFStringRef service, CFDictionaryRef options, void(^)(BOOL))
    private typealias RequestFunc =
        @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    /// 現在の権限状態を（プロンプトを出さずに）取得する。
    static func current() -> Status {
        guard let handle = dlopen(tccPath, RTLD_NOW) else { return .notDetermined }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "TCCAccessPreflight") else { return .notDetermined }
        let preflight = unsafeBitCast(sym, to: PreflightFunc.self)
        switch preflight(serviceName, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .notDetermined
        }
    }

    /// 権限を要求する（未決定なら OS のプロンプトを表示）。完了は main で呼ぶ。
    static func request(_ completion: @escaping (Bool) -> Void) {
        // dlopen したハンドルはコールバックが非同期のため意図的に閉じない。
        guard let handle = dlopen(tccPath, RTLD_NOW),
              let sym = dlsym(handle, "TCCAccessRequest") else {
            // SPI 不可: 暗黙プロンプトに委ねるため、ここでは楽観的に true を返す。
            DispatchQueue.main.async { completion(true) }
            return
        }
        let requestFn = unsafeBitCast(sym, to: RequestFunc.self)
        requestFn(serviceName, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
