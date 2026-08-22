import AppKit
import SwiftUI
import Combine

struct ContentView: View {

    @ObservedObject var model: MixerModel

    // ビューが表示されている間だけ動くタイマー。onAppear/onDisappear は
    // MenuBarExtra(.window) では期待どおりに来ないことがあるため、
    // 表示に紐づくこちらでメーター更新を駆動する。
    // @State で保持する。let にすると body 再評価のたびに作り直され、
    // カウントダウンが振り出しに戻って更新間隔が乱れる。
    @State private var ticker = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// 設定セクションを開いているか。
    @State private var showSettings = false

    /// アプリ一覧の中身の実寸。これに合わせて一覧の高さを変える。
    @State private var listHeight: CGFloat = 0

    /// 一覧の高さの下限と上限。上限を超えたぶんはスクロールする。
    private static let minListHeight: CGFloat = 72
    private static let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.permission != .authorized {
                permissionBanner
            }

            masterSection
            searchBar
            Divider()
            appList

            if model.duckingReason != nil {
                duckingBanner
            }

            // Group でまとめて、外側の VStack が受け取る要素数に余裕を残す。
            // ViewBuilder は 10 個までしか受け取れず、上限に張り付いていると
            // 次に 1 行足したときに分かりにくいコンパイルエラーになる。
            Group {
                // 設定はフッターより上に開く。下に開くと「終了」より後ろに
                // 設定が現れて、並びが逆さまに見える。
                if showSettings {
                    Divider()
                    settingsSection
                }

                Divider()
                footer
            }
        }
        .frame(width: 420)
        // 他のメニューバーアプリと質感を揃える。単色の板より OS に馴染む。
        .background(.regularMaterial)
        .animation(.easeInOut(duration: 0.18), value: model.apps.count)
        .animation(.easeInOut(duration: 0.18), value: showSettings)
        .animation(.easeInOut(duration: 0.18), value: model.duckingReason)
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
        .onReceive(ticker) { _ in model.tick() }
    }

    // MARK: - Header

    /// タイトルと、システムの出力先。デバイス名は押すと切り替えられる。
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(.tint)
            Text("AppMixer")
                .font(.headline)

            Spacer()

            Menu {
                ForEach(model.outputDevices) { device in
                    Button {
                        model.setSystemOutputDevice(device)
                    } label: {
                        // 同名のデバイスが並ぶことがある（同じ機種を 2 台など）。
                        // 名前ではなく UID で今の出力先を見分ける。
                        if device.uid == model.currentOutputUID {
                            Label(device.name, systemImage: "checkmark")
                        } else {
                            Text(device.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "hifispeaker")
                    Text(model.outputName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .fixedSize()
            .foregroundStyle(.secondary)
            .help("システム全体の出力先を切り替えます")
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    // MARK: - Permission

    private var permissionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("システム音声録音の許可が必要です")
                    .font(.caption).fontWeight(.medium)
                Text(model.permission == .denied
                     ? "システム設定で AppMixer を許可してください"
                     : "許可すると音量を調整できます")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if model.permission == .denied {
                Button("設定") { model.openPrivacySettings() }
            } else {
                Button("許可") { model.requestPermission() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Master

    /// アプリ行と同じ 1 行構成にして、視覚的なリズムを揃える。
    private var masterSection: some View {
        HStack(spacing: 10) {
            Button {
                model.setMasterMuted(!model.masterMuted)
            } label: {
                Image(systemName: model.masterMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                    .frame(width: 18)
            }
            .buttonStyle(.borderless)
            .disabled(!model.masterMuteSupported)

            Text("すべて")
                .font(.callout).fontWeight(.medium)
                .frame(width: 46, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(model.masterVolume) },
                    set: { model.setMasterVolume(Float($0)) }
                ),
                in: 0...1
            )
            .controlSize(.small)
            .disabled(!model.masterSupported || model.masterMuted)

            Text(model.masterSupported ? "\(Int((model.masterVolume * 100).rounded()))%" : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.caption)
            TextField("アプリを検索", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.callout)
            Toggle("全アプリ", isOn: $model.showAllApps)
                .toggleStyle(.checkbox)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // MARK: - App list

    private var appList: some View {
        let rows = model.filteredApps
        return Group {
            if rows.isEmpty {
                emptyState
            } else {
                ScrollView {
                    // 遅延生成だと画面外の行が測れず高さが出ないため VStack を使う。
                    // 一覧はせいぜい数十行なので実害はない。
                    VStack(spacing: 0) {
                        ForEach(rows) { display in
                            AppRowView(model: model, display: display)
                        }
                    }
                    .background(
                        // 中身の実寸を測って、その高さに合わせる。
                        // onPreferenceChange ではなく onChange を使う。前者の
                        // クロージャは新しい SDK で @Sendable になっており、
                        // @State への代入が並行性の診断に引っかかる。
                        GeometryReader { geo in
                            Color.clear
                                .onChange(of: geo.size.height, initial: true) { _, height in
                                    listHeight = height
                                }
                        }
                    )
                }
                // ScrollView は放っておくと与えられた高さいっぱいに広がるため、
                // 再生中が 1 つでも余白が残ってしまう。中身の高さに合わせ、
                // 増えすぎたときだけ上限で頭打ちにしてスクロールさせる。
                .frame(height: min(max(listHeight, Self.minListHeight), Self.maxListHeight))
            }
        }
    }

    /// 何も鳴っていないときの表示。ここで手が止まらないよう、
    /// 何をすれば一覧に出るのかまで書く。
    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.showAllApps ? "magnifyingglass" : "speaker.wave.2")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)

            if model.showAllApps {
                Text("アプリが見つかりません")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("再生中のアプリはありません")
                    .font(.callout).foregroundStyle(.secondary)
                Text("音楽や動画を再生すると、ここに表示されます")
                    .font(.caption).foregroundStyle(.tertiary)
                Button("すべてのアプリを表示") { model.showAllApps = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    // MARK: - 自動ダッキング

    /// 発動中だけ出す帯。設定を畳んでいても、いま絞られている理由が分かるようにする。
    private var duckingBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "waveform.badge.mic")
            Text("\(model.duckingReason ?? "") のため音量を下げています")
                .lineLimit(1)
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Color.orange)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    // MARK: - 設定

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("通話中は自動で音量を下げる", isOn: Binding(
                    get: { model.duckingEnabled },
                    set: { model.setDuckingEnabled($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)

                if model.duckingEnabled {
                    HStack(spacing: 8) {
                        Text("下げる音量")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding(
                                get: { Double(model.duckLevel) },
                                set: { model.setDuckLevel(Float($0)) }
                            ),
                            in: 0...1
                        )
                        .controlSize(.small)
                        Text("\(Int((model.duckLevel * 100).rounded()))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }

                    Toggle("マイクの使用も引き金にする", isOn: Binding(
                        get: { model.duckOnMicrophone },
                        set: { model.setDuckOnMicrophone($0) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                .font(.callout)

                if let problem = model.launchAtLoginProblem {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(problem)
                            .foregroundStyle(.secondary)
                        Button("設定を開く") { model.openLoginItemsSettings() }
                            .buttonStyle(.link)
                    }
                    .font(.caption)
                }
            }
        }
        // 外側の VStack は既定で中央寄せのため、幅いっぱいに広げないと
        // 中身の幅しか持たないこのセクションだけ中央に寄ってしまう。
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                showSettings.toggle()
            } label: {
                Label("設定", systemImage: showSettings ? "chevron.down" : "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()

            // 不具合を報告してもらうには、まず版が分からないと始まらない。
            // 押せば報告先が開くので、控える手間もいらない。
            Button {
                openIssues()
            } label: {
                Text(Self.versionLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("問題を報告する（バージョン \(Self.versionLabel)）")

            Spacer()

            Button {
                model.quit()
            } label: {
                Text("終了").font(.caption)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// 表示用のバージョン。Info.plist から読む。
    private static let versionLabel: String = {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        return "v\(short)"
    }()

    private func openIssues() {
        guard let url = URL(string: "https://github.com/iam74k4/AppMixer-MacOS/issues") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
