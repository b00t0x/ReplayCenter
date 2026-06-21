import SwiftUI
import SwiftVLC

struct TileView: View {
    @Bindable var model: TileModel
    let focused: Bool
    let onFocus: () -> Void
    let onOpenChannelSelector: () -> Void

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
                Rectangle()
                    .stroke(focused ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .gesture(tileTapGesture)
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
