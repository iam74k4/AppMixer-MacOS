import Foundation
import ServiceManagement

// ログイン時の自動起動（macOS 13+ の SMAppService）。
//
// SMAppService はアプリバンドルの「場所」を登録する。ビルドし直しても
// dist/AppMixer.app のままなら有効なままだが、アプリを別の場所へ移動すると
// 登録が外れる（.notFound）。その場合は一度オフにして入れ直す必要がある。

enum LaunchAtLogin {

    enum State {
        /// 登録済みで有効。
        case enabled
        /// 未登録。
        case disabled
        /// ユーザーがシステム設定で承認する必要がある。
        case requiresApproval
        /// 登録した場所にアプリが見つからない（移動した等）。
        case notFound
    }

    static var state: State {
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound:         return .notFound
        case .notRegistered:    return .disabled
        @unknown default:       return .disabled
        }
    }

    static var isEnabled: Bool { state == .enabled }

    /// 自動起動を切り替える。失敗した理由を返す（成功時は nil）。
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                // 既に登録済みで register() を呼ぶとエラーになる実装があるため、
                // 状態を見てから呼ぶ。
                guard SMAppService.mainApp.status != .enabled else { return nil }
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            NSLog("[AppMixer] Launch at login \(enabled ? "register" : "unregister") failed: \(error)")
            return error.localizedDescription
        }
    }

    /// ログイン項目の設定画面を開く（承認が必要なときの導線）。
    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
