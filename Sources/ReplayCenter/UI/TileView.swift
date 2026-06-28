import SwiftUI
import SwiftVLC

struct TileView: View {
    @Bindable var model: TileModel
    let focused: Bool
    let dropTarget: Bool
    let volumePercent: Int
    let showStreamInfo: Bool
    let showFocusRing: Bool
    let onFocus: () -> Void
    let onOpenChannelSelector: () -> Void
    let onSetAudioSelection: (AudioSelection) -> Void
    let onToggleMuted: () -> Void
    let onDecreaseVolume: () -> Void
    let onIncreaseVolume: () -> Void
    let onReload: () -> Void
    let onClear: () -> Void
    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false

    var body: some View {
        GeometryReader { proxy in
            VideoView(model.player)
                .background(Color.black)
                .overlay {
                    if model.stream == nil {
                        ZStack {
                            Rectangle()
                                .fill(.regularMaterial)
                            Rectangle()
                                .fill(Color.white.opacity(0.06))
                        }
                    }
                }
                .overlay {
                    if model.stream == nil {
                        Rectangle()
                            .stroke(Color.white.opacity(isHovering ? 0.28 : 0.16), lineWidth: 1)
                    }
                }
                .overlay(alignment: .topLeading) {
                    Text(title)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.black.opacity(labelBackgroundOpacity))
                        .foregroundStyle(labelColor)
                }
                .overlay {
                    if let statusText = model.playbackState.displayText {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.65))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if isHovering, model.stream != nil, showStreamInfo {
                        Text(model.streamInfoText(displayPixelSize: displayPixelSize(for: proxy.size)))
                            .font(.caption2.monospaced())
                            .multilineTextAlignment(.trailing)
                            .lineLimit(5)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.72))
                            .foregroundStyle(.white)
                            .padding(6)
                    }
                }
                .overlay {
                    Rectangle()
                        .stroke(focusStrokeColor, lineWidth: dropTarget ? 5 : 2)
                }
                .overlay(alignment: .bottom) {
                    if isHovering {
                        if focused {
                            FocusedTileControlsView(
                                hasStream: model.stream != nil,
                                audioSelection: model.currentAudioSelection,
                                audioStreamState: model.audioStreamState,
                                isMuted: model.isMuted,
                                volumePercent: volumePercent
                            ) {
                                onOpenChannelSelector()
                            } onSetAudioSelection: { selection in
                                onFocus()
                                onSetAudioSelection(selection)
                            } onToggleMuted: {
                                onToggleMuted()
                            } onDecreaseVolume: {
                                onDecreaseVolume()
                            } onIncreaseVolume: {
                                onIncreaseVolume()
                            } onReload: {
                                onFocus()
                                onReload()
                            } onClear: {
                                onFocus()
                                onClear()
                            }
                            .padding(.bottom, 8)
                        } else {
                            ChannelOnlyTileControlsView(onChangeChannel: onOpenChannelSelector)
                                .padding(.bottom, 8)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(tileTapGesture)
                .onHover { hovering in
                    isHovering = hovering
                }
                .task {
                    model.startIfNeeded()
                }
        }
    }

    private func displayPixelSize(for pointSize: CGSize) -> CGSize {
        CGSize(
            width: pointSize.width * displayScale,
            height: pointSize.height * displayScale
        )
    }

    private var title: String {
        guard let stream = model.stream else { return "未割り当て" }
        return stream.title ?? stream.url
    }

    private var labelBackgroundOpacity: Double {
        model.stream == nil ? 0.35 : 0.58
    }

    private var labelColor: Color {
        model.stream == nil ? .secondary : .white
    }

    private var statusColor: Color {
        model.playbackState.isFailure ? .red : .white
    }

    private var focusStrokeColor: Color {
        if dropTarget {
            return Color.white.opacity(0.86)
        }
        return focused && showFocusRing ? Color.accentColor : Color.clear
    }

    private var tileTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                onOpenChannelSelector()
            }
            .exclusively(
                before: TapGesture(count: 1)
                    .onEnded {
                        onFocus()
                    }
            )
    }
}

private struct ChannelOnlyTileControlsView: View {
    let onChangeChannel: () -> Void

    var body: some View {
        Button(action: onChangeChannel) {
            HStack(spacing: 4) {
                Image(systemName: "tv")
                    .frame(width: 14)
                Text("選局")
            }
            .font(.caption)
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .background(.black.opacity(0.72))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help("チャンネルを選択")
    }
}
