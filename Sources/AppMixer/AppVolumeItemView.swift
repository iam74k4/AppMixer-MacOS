import AppKit

// メニュー内 1 アプリ分の行ビュー: [アイコン] 名前 / [🔇] [====スライダー====] [xx%]
@available(macOS 14.2, *)
final class AppVolumeItemView: NSView {

    private let process: AudioProcess
    private weak var mixer: MixerController?

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let muteButton = NSButton()
    private let slider = NSSlider()
    private let percentLabel = NSTextField(labelWithString: "")

    init(process: AudioProcess, mixer: MixerController) {
        self.process = process
        self.mixer = mixer
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 52))
        setupSubviews()
        syncFromState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupSubviews() {
        // 自身は init のフレーム(300x52)をそのまま使い、内部のみ Auto Layout。
        iconView.image = process.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.stringValue = process.name
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        muteButton.setButtonType(.toggle)
        muteButton.bezelStyle = .regularSquare
        muteButton.isBordered = false
        muteButton.title = ""
        muteButton.image = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: "Mute")
        muteButton.alternateImage = NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: "Unmute")
        muteButton.target = self
        muteButton.action = #selector(toggleMute)
        muteButton.translatesAutoresizingMaskIntoConstraints = false

        slider.minValue = 0.0
        slider.maxValue = 1.0
        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.textColor = .secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(muteButton)
        addSubview(slider)
        addSubview(percentLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            muteButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            muteButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            muteButton.widthAnchor.constraint(equalToConstant: 20),
            muteButton.heightAnchor.constraint(equalToConstant: 20),

            slider.leadingAnchor.constraint(equalTo: muteButton.trailingAnchor, constant: 8),
            slider.centerYAnchor.constraint(equalTo: muteButton.centerYAnchor),

            percentLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 8),
            percentLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            percentLabel.centerYAnchor.constraint(equalTo: muteButton.centerYAnchor),
            percentLabel.widthAnchor.constraint(equalToConstant: 38),
        ])
    }

    private func syncFromState() {
        guard let mixer else { return }
        let state = mixer.state(for: process)
        slider.floatValue = state.volume
        muteButton.state = state.muted ? .on : .off
        updatePercent(state.volume, muted: state.muted)
    }

    private func updatePercent(_ volume: Float, muted: Bool) {
        percentLabel.stringValue = muted ? "—" : "\(Int((volume * 100).rounded()))%"
        slider.isEnabled = !muted
    }

    @objc private func sliderChanged() {
        guard let mixer else { return }
        let value = slider.floatValue
        mixer.setVolume(value, for: process)
        updatePercent(value, muted: mixer.state(for: process).muted)
    }

    @objc private func toggleMute() {
        guard let mixer else { return }
        let muted = muteButton.state == .on
        mixer.setMuted(muted, for: process)
        updatePercent(slider.floatValue, muted: muted)
    }
}
