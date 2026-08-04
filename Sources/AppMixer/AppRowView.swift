import SwiftUI

struct AppRowView: View {

    @ObservedObject var model: MixerModel
    let display: MixerModel.DisplayApp

    private var app: AudioApp { display.app }

    var body: some View {
        HStack(spacing: 10) {
            icon

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(app.name)
                        .font(.callout).fontWeight(.medium)
                        .lineLimit(1)
                    if display.failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help("音量を適用できませんでした。実際の音量は変わっていません。")
                    } else if !app.isRunningOutput {
                        Text("停止中")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(display.muted ? "—" : "\(Int((display.volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Button {
                        model.setMuted(!display.muted, for: app)
                    } label: {
                        Image(systemName: display.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)

                    Slider(
                        value: Binding(
                            get: { Double(display.volume) },
                            set: { model.setVolume(Float($0), for: app) }
                        ),
                        in: 0...1
                    )
                    .disabled(display.muted)
                }

                // タップが張られているときだけメーターを表示する
                // （100% のアプリはタップを張らないためレベルを計測できない）
                if display.metered {
                    meterBar
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

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
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
    }

    private var meterBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(meterColor)
                    .frame(width: geo.size.width * CGFloat(min(1, max(0, display.level))))
            }
        }
        .frame(height: 3)
    }

    private var meterColor: Color {
        switch display.level {
        case ..<0.7: return .green
        case ..<0.9: return .yellow
        default:     return .red
        }
    }
}
