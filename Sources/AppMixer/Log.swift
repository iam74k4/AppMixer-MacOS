import os

// アプリ共通のログ出力先。
//
// NSLog は書いた文字列がそのまま端末やコンソールに残る。ここで扱うのは
// 「どのアプリで音を鳴らしているか」という利用者の行動そのものなので、
// アプリ名やバンドル ID は既定で伏せられる os.Logger を使い、
// 伏せ字を外すのは開発者が明示的に設定したときだけにする。
enum AppLog {
    private static let subsystem = "io.github.iam74k4.AppMixer"

    /// タップの生成/破棄まわり。
    static let audio = Logger(subsystem: subsystem, category: "audio")

    /// 設定の保存と復元。
    static let settings = Logger(subsystem: subsystem, category: "settings")
}
