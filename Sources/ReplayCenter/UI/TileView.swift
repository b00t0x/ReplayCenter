import AppKit
import SwiftUI
import SwiftVLC

struct TileView: View {
    @Bindable var model: TileModel
    let focused: Bool
    let dropTarget: Bool
    let volumePercent: Int
    let showStreamInfo: Bool
    let showFocusRing: Bool
    let hoverInteractionsActive: Bool
    let topOverlayInset: CGFloat
    let channelProgramInfo: ChannelProgramOverlayInfo?
    let channelProgramOverlayVisibility: ChannelProgramOverlayVisibility
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
            tileSurface
                .overlay {
                    if model.stream == nil {
                        EmptyTilePanelStroke(isHovering: effectiveIsHovering)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if showsChannelProgramOverlay {
                        TileChannelProgramOverlayView(
                            info: effectiveChannelProgramInfo,
                            labelColor: labelColor,
                            backgroundOpacity: labelBackgroundOpacity,
                            maxWidth: max(proxy.size.width * 0.56, 80)
                        )
                        .padding(.top, topOverlayInset)
                    }
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
                    if effectiveIsHovering, model.stream != nil, showStreamInfo {
                        Text(model.streamInfoText(displayPixelSize: displayPixelSize(for: proxy.size)))
                            .font(.caption2.monospaced())
                            .multilineTextAlignment(.trailing)
                            .lineLimit(5)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.72))
                            .foregroundStyle(.white)
                            .padding(.top, topOverlayInset)
                            .padding(.trailing, 6)
                    }
                }
                .overlay {
                    Rectangle()
                        .stroke(focusStrokeColor, lineWidth: dropTarget ? 5 : 2)
                }
                .overlay(alignment: .bottom) {
                    if effectiveIsHovering {
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
                            ChannelOnlyTileControlsView(
                                hasStream: model.stream != nil,
                                onChangeChannel: onOpenChannelSelector,
                                onClear: onClear
                            )
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

    @ViewBuilder
    private var tileSurface: some View {
        if model.stream == nil {
            EmptyTilePanelBackground(isHovering: effectiveIsHovering)
        } else {
            VideoView(model.player)
                .background(Color.black)
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

    private var effectiveChannelProgramInfo: ChannelProgramOverlayInfo {
        channelProgramInfo ?? ChannelProgramOverlayInfo(
            channelName: title,
            programName: nil,
            programTimeText: nil
        )
    }

    private var showsChannelProgramOverlay: Bool {
        switch channelProgramOverlayVisibility {
        case .always:
            return true
        case .onHover:
            return effectiveIsHovering
        }
    }

    private var effectiveIsHovering: Bool {
        isHovering && hoverInteractionsActive
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

struct EmptyTilePanelBackground: View {
    let isHovering: Bool

    var body: some View {
        ZStack {
            BehindWindowVisualEffectView(
                material: .popover,
                alphaValue: 1
            )
            Rectangle()
                .fill(Color.white.opacity(isHovering ? 0.08 : 0.05))
        }
    }
}

struct EmptyTilePanelStroke: View {
    let isHovering: Bool

    var body: some View {
        Rectangle()
            .stroke(Color.black.opacity(isHovering ? 0.24 : 0.16), lineWidth: 1)
    }
}

private struct BehindWindowVisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let alphaValue: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = material
        view.alphaValue = alphaValue
        view.state = .active
        view.isEmphasized = false
        view.wantsLayer = true
        view.layer?.isOpaque = false
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = .behindWindow
        view.alphaValue = alphaValue
        view.state = .active
    }
}

private struct TileChannelProgramOverlayView: View {
    let info: ChannelProgramOverlayInfo
    let labelColor: Color
    let backgroundOpacity: Double
    let maxWidth: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(info.channelName)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: maxWidth, alignment: .leading)
            if let programLine {
                Text(programLine)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: maxWidth, alignment: .leading)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(.black.opacity(backgroundOpacity))
        .foregroundStyle(labelColor)
    }

    private var programLine: String? {
        guard let programName = info.programName else { return nil }
        if let programTimeText = info.programTimeText {
            return "\(programTimeText) \(programName)"
        }
        return programName
    }
}

private struct ChannelOnlyTileControlsView: View {
    let hasStream: Bool
    let onChangeChannel: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            controlButton(title: "選局", systemImage: "tv", action: onChangeChannel)
                .help("チャンネルを選択")

            if hasStream {
                controlButton(title: nil, systemImage: "xmark", action: onClear)
                    .help("タイルをクリア")
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.black.opacity(0.72))
        .foregroundStyle(.white)
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
}
