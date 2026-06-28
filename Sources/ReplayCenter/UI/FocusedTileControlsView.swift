import SwiftUI

struct FocusedTileControlsView: View {
    let hasStream: Bool
    let audioSelection: AudioSelection
    let audioStreamState: AudioStreamState
    let isMuted: Bool
    let volumePercent: Int
    let onChangeChannel: () -> Void
    let onSetAudioSelection: (AudioSelection) -> Void
    let onToggleMuted: () -> Void
    let onDecreaseVolume: () -> Void
    let onIncreaseVolume: () -> Void
    let onReload: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            controlButton(title: "選局", systemImage: "tv", action: onChangeChannel)
                .help("チャンネルを選択")

            Divider()
                .frame(height: 18)

            audioButton(selection: .primary)
                .help("主音声")
            audioButton(selection: .secondary)
                .help("副音声")

            Divider()
                .frame(height: 18)

            controlButton(
                title: nil,
                systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                action: onToggleMuted
            )
            .disabled(!hasStream)
            .help(isMuted ? "ミュート解除" : "ミュート")

            volumeControls

            Divider()
                .frame(height: 18)

            controlButton(title: nil, systemImage: "arrow.clockwise", action: onReload)
                .disabled(!hasStream)
                .help("再読み込みして追いつく")

            controlButton(title: nil, systemImage: "xmark", action: onClear)
                .disabled(!hasStream)
                .help("タイルをクリア")
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.72))
        .foregroundStyle(.white)
    }

    private var volumeControls: some View {
        HStack(spacing: 3) {
            iconButton(systemImage: "minus", action: onDecreaseVolume)
                .disabled(volumePercent <= VolumeLevel.minimum)
                .help("音量を下げる")

            Text("\(volumePercent)%")
                .font(.caption.monospacedDigit().weight(.semibold))
                .frame(width: 42, height: 22)
                .background(Color.white.opacity(0.12))

            iconButton(systemImage: "plus", action: onIncreaseVolume)
                .disabled(volumePercent >= VolumeLevel.maximum)
                .help("音量を上げる")
        }
    }

    private func audioButton(selection: AudioSelection) -> some View {
        Button {
            onSetAudioSelection(selection)
        } label: {
            Text(selection.displayText)
                .font(.caption.weight(.semibold))
                .frame(width: 28, height: 22)
                .background(audioSelection == selection ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.12))
        }
        .buttonStyle(.plain)
        .disabled(!hasStream || !audioStreamState.supportsAudioSelectionControls)
    }

    private func controlButton(title: String?, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .frame(width: 14)
                if let title {
                    Text(title)
                }
            }
            .frame(minWidth: title == nil ? 24 : 0, minHeight: 22)
            .padding(.horizontal, title == nil ? 2 : 5)
            .background(Color.white.opacity(0.12))
        }
        .buttonStyle(.plain)
    }

    private func iconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.12))
        }
        .buttonStyle(.plain)
    }
}
