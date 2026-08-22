import AppKit
import Darwin

// 音を出しているプロセスの「本体アプリ」を解決する。
//
// Chromium/Electron 系（Edge, Chrome, Discord, Slack, VS Code…）は
// 音声をヘルパーの子プロセスから出すため、CoreAudio が返す pid は
// "com.microsoft.edge.helper" のようなヘルパーになる。
// 親 pid を辿って、アイコンと分かりやすい名前を持つ通常アプリ
// (NSRunningApplication / activationPolicy == .regular) を見つける。

enum ProcessIdentity {

    /// pid が属する本体アプリ（見つからなければ nil）。
    static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        var depth = 0

        while current > 1 && depth < 16 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular,
               app.bundleIdentifier != nil {
                return app
            }
            guard let parent = parentPID(of: current), parent != current else { break }
            current = parent
            depth += 1
        }

        // フォールバック: 直接の pid でアプリが取れればそれを使う
        return NSRunningApplication(processIdentifier: pid)
    }

    /// 指定 pid の親 pid を sysctl(KERN_PROC) で取得する。
    static func parentPID(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { buffer -> Int32 in
            sysctl(buffer.baseAddress, u_int(buffer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let ppid = info.kp_eproc.e_ppid
        return ppid > 0 ? ppid : nil
    }
}
