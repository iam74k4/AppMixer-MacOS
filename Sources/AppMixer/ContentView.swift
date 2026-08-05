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
    private static let minListHeight: CGFloat = 64
    private static let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if model.permission != .authorized {
                permissionBanner
                Divider()
            }

            masterSection
            Divider()
            searchBar
            Divider()
            appList

            if model.duckingReason != nil {
                Divider()
                duckingBanner
            }

            Divider()
            footer

            // 設定は既定で畳んでおく。常に開いていると縦に長くなり、
            // 主役であるアプリ一覧が埋もれてしまう。
            if showSettings {
                Divider()
                duckingSection
                Divider()
                launchAtLoginSection
            }
        }
        .frame(width: 420)
        .onAppear { model.onAppear() }
        .onDisappear { model.onDisappear() }
        .onReceive(ticker) { _ in model.tick() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .foregroundStyle(.tint)
            Text("AppMixer")
                .font(.headline)
            Spacer()
            Text(model.outputName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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

            VStack(alignment: .leading, spacing: 1) {
                Text("マスター")
                    .font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { Double(model.masterVolume) },
                        set: { model.setMasterVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .disabled(!model.masterSupported || model.masterMuted)
            }

            Text(model.masterSupported ? "\(Int((model.masterVolume * 100).rounded()))%" : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
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
        .padding(.vertical, 8)
    }

    // MARK: - App list

    private var appList: some View {
        // 一度だけ絞り込む。ForEach の中で参照すると行数ぶん再計算される。
        let rows = model.filteredApps
        return Group {
            if rows.isEmpty {
                Text(model.showAllApps ? "アプリが見つかりません" : "再生中のアプリはありません")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    // 遅延生成だと画面外の行が測れず高さが出ないため VStack を使う。
                    // 一覧はせいぜい数十行なので実害はない。
                    VStack(spacing: 0) {
                        ForEach(rows) { display in
                            AppRowView(model: model, display: display)
                            if display.id != rows.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                    .background(
                        // 中身の実寸を測って、その高さにポップオーバーを合わせる。
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

    private var duckingSection: some View {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Launch at login

    private var launchAtLoginSection: some View {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                model.refresh()
            } label: {
                Label("更新", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()

            Button {
                showSettings.toggle()
            } label: {
                Label("設定", systemImage: showSettings ? "chevron.down" : "gearshape")
                    .font(.caption)
            }
            .buttonStyle(.borderless)

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
}
