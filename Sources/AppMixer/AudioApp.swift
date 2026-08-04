import AppKit
import CoreAudio

// アプリ単位にまとめた音声プロセス群。
// 1つのアプリ（例: Microsoft Edge）が複数の音声ヘルパーを持つため、
// それらを本体アプリ単位でグルーピングし、1行=1アプリで扱う。

struct AudioApp: Identifiable, Equatable {
    let id: String                       // bundleID（無ければ "pid:<owner>"）。永続化キーも兼ねる
    let bundleID: String?
    let name: String
    let processObjectIDs: [AudioObjectID] // このアプリの全音声プロセスオブジェクト（タップ対象）
    let pids: [pid_t]
    let isRunningOutput: Bool             // いずれかのプロセスが現在出力中か

    private let iconAppPID: pid_t?        // アイコン取得用の本体アプリ pid

    init(id: String, bundleID: String?, name: String,
         processObjectIDs: [AudioObjectID], pids: [pid_t],
         isRunningOutput: Bool, iconAppPID: pid_t?) {
        self.id = id
        self.bundleID = bundleID
        self.name = name
        self.processObjectIDs = processObjectIDs
        self.pids = pids
        self.isRunningOutput = isRunningOutput
        self.iconAppPID = iconAppPID
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id &&
        lhs.processObjectIDs == rhs.processObjectIDs &&
        lhs.isRunningOutput == rhs.isRunningOutput
    }

    var icon: NSImage? {
        if let pid = iconAppPID, let app = NSRunningApplication(processIdentifier: pid) {
            return app.icon
        }
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }
}

enum AudioAppEnumerator {

    private static let ownBundleID = Bundle.main.bundleIdentifier

    /// 全ての音声プロセスを本体アプリ単位にまとめて返す。
    static func enumerate() -> [AudioApp] {
        let objectIDs = CoreAudioObject.readArray(.system, selector: kAudioHardwarePropertyProcessObjectList)

        // key -> 集約中データ
        final class Builder {
            var bundleID: String?
            var name: String
            var iconAppPID: pid_t?
            var objectIDs: [AudioObjectID] = []
            var pids: [pid_t] = []
            var runningOutput = false
            init(bundleID: String?, name: String, iconAppPID: pid_t?) {
                self.bundleID = bundleID
                self.name = name
                self.iconAppPID = iconAppPID
            }
        }

        var builders: [String: Builder] = [:]

        for objectID in objectIDs {
            let pid: pid_t = CoreAudioObject.read(objectID, selector: kAudioProcessPropertyPID, defaultValue: pid_t(-1))
            guard pid > 0 else { continue }

            let owningApp = ProcessIdentity.owningApplication(of: pid)
            let bundleID = owningApp?.bundleIdentifier
                ?? CoreAudioObject.readString(objectID, selector: kAudioProcessPropertyBundleID)

            // 自分自身は除外
            if let bundleID, bundleID == ownBundleID { continue }

            // 本体アプリも bundleID も取れないシステム音声は除外
            let name: String
            if let localized = owningApp?.localizedName, !localized.isEmpty {
                name = localized
            } else if let bundleID {
                name = bundleID
            } else {
                continue
            }

            let key = bundleID ?? "pid:\(owningApp?.processIdentifier ?? pid)"

            let builder = builders[key] ?? Builder(
                bundleID: bundleID, name: name, iconAppPID: owningApp?.processIdentifier
            )
            builder.objectIDs.append(objectID)
            builder.pids.append(pid)
            if isRunningOutput(objectID) { builder.runningOutput = true }
            builders[key] = builder
        }

        let apps = builders.map { key, b in
            AudioApp(
                id: key,
                bundleID: b.bundleID,
                name: b.name,
                processObjectIDs: b.objectIDs,
                pids: b.pids,
                isRunningOutput: b.runningOutput,
                iconAppPID: b.iconAppPID
            )
        }

        // 同名・同状態のアプリで順序が揺れると一覧を作り直し続けてしまうため、
        // id で必ず決着をつける。
        return apps.sorted {
            if $0.isRunningOutput != $1.isRunningOutput { return $0.isRunningOutput }
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            if order != .orderedSame { return order == .orderedAscending }
            return $0.id < $1.id
        }
    }

    /// このプロセスが今まさに音を出しているか。
    /// IsRunningOutput を持たないプロセスオブジェクトもあるため、
    /// 無い場合は IsRunning にフォールバックする。これを怠ると、
    /// 実際は再生中のアプリが一覧から漏れる。
    private static func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        if CoreAudioObject.hasProperty(objectID, selector: kAudioProcessPropertyIsRunningOutput) {
            // このプロパティがあるなら、その値がそのまま答え。
            // false のときに IsRunning へ落とすと、入力だけのプロセス
            // （通話中のマイクなど）まで「再生中」と誤判定してしまう。
            let value: UInt32 = CoreAudioObject.read(
                objectID, selector: kAudioProcessPropertyIsRunningOutput, defaultValue: 0
            )
            return value != 0
        }
        if CoreAudioObject.hasProperty(objectID, selector: kAudioProcessPropertyIsRunning) {
            let value: UInt32 = CoreAudioObject.read(
                objectID, selector: kAudioProcessPropertyIsRunning, defaultValue: 0
            )
            return value != 0
        }
        return false
    }
}
