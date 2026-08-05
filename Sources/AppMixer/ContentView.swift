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
            Divider()
            launchAtLoginSection
            Divider()
            footer
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
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { display in
                            AppRowView(model: model, display: display)
                            if display.id != rows.last?.id {
                                Divider().padding(.leading, 44)
                            }
                        }
                    }
                }
                .frame(maxHeight: 460)
            }
        }
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
