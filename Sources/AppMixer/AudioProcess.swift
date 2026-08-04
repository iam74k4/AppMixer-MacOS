import AppKit
import CoreAudio

// 音声を出しているアプリ（プロセス）のモデルと列挙。

struct AudioProcess: Identifiable, Equatable {
    let id: AudioObjectID     // Core Audio のプロセスオブジェクト ID（タップ対象）
    let pid: pid_t
    let bundleID: String?
    let name: String
    let isRunningOutput: Bool

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.pid == rhs.pid
    }

    var icon: NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }
}

@available(macOS 14.2, *)
enum AudioProcessController {

    /// 現在 Core Audio に認識されているプロセスのうち、出力中のものを列挙する。
    static func runningOutputProcesses() -> [AudioProcess] {
        let objectIDs = CoreAudioObject.readArray(.system, selector: kAudioHardwarePropertyProcessObjectList)
        var results: [AudioProcess] = []

        for objectID in objectIDs {
            let pid: pid_t = CoreAudioObject.read(objectID, selector: kAudioProcessPropertyPID, defaultValue: pid_t(-1))
            guard pid > 0 else { continue }

            // 出力中フラグ（UInt32 の 0/1）
            let runningOutput: UInt32 = CoreAudioObject.read(
                objectID, selector: kAudioProcessPropertyIsRunningOutput, defaultValue: 0
            )
            guard runningOutput != 0 else { continue }

            let bundleID = CoreAudioObject.readString(objectID, selector: kAudioProcessPropertyBundleID)
            let name = displayName(pid: pid, bundleID: bundleID)

            results.append(
                AudioProcess(
                    id: objectID,
                    pid: pid,
                    bundleID: bundleID,
                    name: name,
                    isRunningOutput: true
                )
            )
        }

        // 名前で安定ソート
        return results.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func displayName(pid: pid_t, bundleID: String?) -> String {
        if let app = NSRunningApplication(processIdentifier: pid),
           let localized = app.localizedName, !localized.isEmpty {
            return localized
        }
        if let bundleID, !bundleID.isEmpty {
            return bundleID
        }
        return "PID \(pid)"
    }
}
