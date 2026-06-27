import SwiftUI
import SwiftVLC

struct TileView: View {
    @Bindable var model: TileModel
    let focused: Bool
    let onFocus: () -> Void
    let onOpenChannelSelector: () -> Void
    let onSetAudioSelection: (AudioSelection) -> Void
    let onToggleMuted: () -> Void
    let onReload: () -> Void
    let onClear: () -> Void
    @State private var isHovering = false

    var body: some View {
        VideoView(model.player)
            .background(Color.black)
            .overlay {
                if model.stream == nil {
                    Color.black
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
            .overlay {
                Rectangle()
                    .stroke(focused ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .overlay(alignment: .bottom) {
                if focused && isHovering {
                    FocusedTileControlsView(
                        hasStream: model.stream != nil,
                        audioSelection: model.currentAudioSelection,
                        audioStreamState: model.audioStreamState,
                        isMuted: model.isMuted
                    ) {
                        onFocus()
                        onOpenChannelSelector()
                    } onSetAudioSelection: { selection in
                        onFocus()
                        onSetAudioSelection(selection)
                    } onToggleMuted: {
                        onToggleMuted()
                    } onReload: {
                        onFocus()
                        onReload()
                    } onClear: {
                        onFocus()
                        onClear()
                    }
                    .padding(.bottom, 8)
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

    private var tileTapGesture: some Gesture {
        TapGesture(count: 2)
            .onEnded {
                onFocus()
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
