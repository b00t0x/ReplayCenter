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
            .overlay(alignment: .topLeading) {
                Text(model.stream.title ?? model.stream.url)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.58))
                    .foregroundStyle(.white)
            }
            .overlay {
                Rectangle()
                    .stroke(focused ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onFocus()
            }
            .onTapGesture(count: 2) {
                onFocus()
                onOpenChannelSelector()
            }
            .task {
                model.startIfNeeded()
            }
    }
}
