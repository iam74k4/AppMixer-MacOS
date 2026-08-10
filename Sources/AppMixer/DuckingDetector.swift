import Foundation
import CoreAudio

// 「いま通話中か」を判定する。
//
// 判定材料は 2 つ:
//   1. マイクを使っているプロセスがある（kAudioProcessPropertyIsRunningInput）
//   2. 既知の通話アプリが音を出している
//
// 1 だけだと録音アプリでも反応し、2 だけだと未知の通話アプリを拾えないため、
// 両方を見る。どちらかが成立すれば「通話中」とみなす。

enum DuckingDetector {

    /// 会議アプリ。音を出していること自体を通話の合図として扱う。
    /// チャットアプリ（Discord/Slack 等）はここに入れない。
    /// 通知音のたびに音楽が下がってしまうため、そちらはマイク検知に任せる。
    static let meetingBundlePrefixes: [String] = [
        "us.zoom",
        "com.microsoft.teams",
        "com.microsoft.SkypeForBusiness",
        "com.apple.FaceTime",
        "com.google.Chrome.meet",
        "com.webex",
        "com.cisco.webex",
        "com.ringcentral",
        "com.amazon.Amazon-Chime"
    ]

    /// 通話に使われうるアプリ。ダッキングの対象外にする
    /// （相手の声まで絞ってしまわないため）。会議アプリを含む上位集合。
    static let communicationBundlePrefixes: [String] = meetingBundlePrefixes + [
        "com.hnc.Discord",
        "com.tinyspeck.slackmacgap",
        "com.skype"
    ]

    /// 対象アプリが通話に使われうるか（＝絞ってはいけないか）。
    static func isCommunicationApp(_ app: AudioApp) -> Bool {
        matches(app, prefixes: communicationBundlePrefixes)
    }

    /// 対象アプリが会議アプリか（＝出音を通話の合図とみなすか）。
    static func isMeetingApp(_ app: AudioApp) -> Bool {
        matches(app, prefixes: meetingBundlePrefixes)
    }

    private static func matches(_ app: AudioApp, prefixes: [String]) -> Bool {
        guard let bundleID = app.bundleID?.lowercased() else { return false }
        return prefixes.contains { bundleID.hasPrefix($0.lowercased()) }
    }

    /// 現在ダッキングすべきか、そのきっかけになったアプリ名とともに返す。
    ///
    /// マイクの判定は渡された一覧から読む。以前はここでプロセス一覧を
    /// もう一度引いていたが、この関数はダッキングが有効な間ずっと毎秒
    /// 呼ばれるため、走査は 1 回で済ませる。
    static func evaluate(apps: [AudioApp], useMicrophone: Bool) -> String? {
        if let app = apps.first(where: { $0.isRunningOutput && isMeetingApp($0) }) {
            return app.name
        }
        if useMicrophone, apps.contains(where: \.isRunningInput) {
            return "マイク使用中"
        }
        return nil
    }
}
