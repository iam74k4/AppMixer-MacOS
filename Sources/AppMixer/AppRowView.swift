import SwiftUI

struct AppRowView: View {

    @ObservedObject var model: MixerModel
    let display: MixerModel.DisplayApp

    /// カーソルが乗っている間だけ、普段は伏せている操作を出す。
    @State private var isHovered = false

    private var app: AudioApp { display.app }

    /// 既定から動かしている行は、ホバーしていなくても操作を見せておく。
    /// そうしないと「なぜこのアプリだけ音が違うのか」が分からなくなる。
    private var showsControls: Bool {
        isHovered || display.muted || display.outputDeviceUID != nil
            || display.volume < 0.999
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                icon

                VStack(alignment: .leading, spacing: 5) {
                    titleLine
                    controlLine
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider().padding(.leading, 44)
        }
        .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        .opacity(app.isRunningOutput ? 1.0 : 0.55)
        .onHover { isHovered = $0 }
    }

    // MARK: - 1 段目: 名前・状態・出力先・音量値

    private var titleLine: some View {
        HStack(spacing: 6) {
            Text(app.name)
                .font(.callout).fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)

            statusBadge

            Spacer(minLength: 6)

            if showsControls {
                outputMenu
            }

            Text(display.muted ? "ミュート" : "\(Int((display.volume * 100).rounded()))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(display.muted ? Color.secondary : Color.primary)
                .frame(width: 52, alignment: .trailing)
                // 枠いっぱいを当たり判定にする。これが無いと数字の字面の上
                // でしかダブルクリックを拾えない。
                .contentShape(Rectangle())
                .help(volumeHelp)
                // スライダーを掴んで戻すより速い、定番の操作。
                .onTapGesture(count: 2) {
                    model.setVolume(1.0, for: app)
                }
        }
    }

    private var volumeHelp: String {
        "この音量は「\(model.memoryDeviceName(for: app))」に対して記憶されます。"
            + "ダブルクリックで 100% に戻します"
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let trouble = display.trouble {
            Image(systemName: trouble == .silenced
                  ? "speaker.slash.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption2)
                .foregroundStyle(trouble == .silenced ? Color.red : Color.orange)
                .help(trouble.message)
        } else if display.ducked {
            Image(systemName: "arrow.down.right.circle.fill")
                .font(.caption2)
                .foregroundStyle(Color.orange)
                .help("通話中のため自動で音量を下げています")
        }
    }

    // MARK: - 2 段目: ミュート + スライダー（直下にメーター）

    private var controlLine: some View {
        HStack(spacing: 8) {
            // ホバー前も場所は確保しておく。出し入れで幅が動くと目障りなため。
            Button {
                model.setMuted(!display.muted, for: app)
            } label: {
                Image(systemName: display.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 16)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(display.muted ? Color.accentColor : Color.secondary)
            .opacity(showsControls ? 1 : 0)
            .allowsHitTesting(showsControls)

            // スライダーとメーターを同じ幅・同じ開始位置に揃えると、
            // メーターが「そのスライダーのレベル」として読める。
            VStack(alignment: .leading, spacing: 3) {
                Slider(
                    value: Binding(
                        get: { Double(display.volume) },
                        set: { model.setVolume(Float($0), for: app) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(display.muted)

                meterBar
            }
        }
    }

    // MARK: - Parts

    private var icon: some View {
        Group {
            if let icon = display.icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(width: 30, height: 30)
    }

    /// 出力先の選択。既定のままならアイコンだけの控えめな表示にして、
    /// 別デバイスへ振っているときだけデバイス名を出す。
    private var outputMenu: some View {
        Menu {
            Button {
                model.setOutputDevice(nil, for: app)
            } label: {
                if display.outputDeviceUID == nil {
                    Label("既定の出力", systemImage: "checkmark")
                } else {
                    Text("既定の出力")
                }
            }
            Divider()
            ForEach(model.outputDevices) { device in
                Button {
                    model.setOutputDevice(device.uid, for: app)
                } label: {
                    if display.outputDeviceUID == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            if display.outputDeviceUID == nil {
                Image(systemName: "hifispeaker")
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "hifispeaker.fill")
                    Text(model.outputDeviceName(display.outputDeviceUID))
                        .lineLimit(1)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .font(.caption)
        .foregroundStyle(display.outputDeviceUID == nil ? Color.secondary : Color.accentColor)
        .help("このアプリの出力先を選ぶ")
    }

    private var meterBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(meterColor)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, display.level))))
                    .animation(.linear(duration: 0.05), value: display.level)
            }
        }
        .frame(height: 4)
        // 計測できていない行は伸びようがないので、出しても誤解を招く。
        .opacity(app.isRunningOutput && display.metered ? 1 : 0)
    }

    private var meterColor: Color {
        switch display.level {
        case ..<0.7: return .green
        case ..<0.9: return .yellow
        default:     return .red
        }
    }
}
