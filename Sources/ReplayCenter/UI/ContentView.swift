import SwiftUI

struct ContentView: View {
    @Bindable var model: TileGridModel
    let channelCatalog: ChannelCatalogModel?
    @State private var isChannelSelectorPresented = false

    var body: some View {
        Group {
            if model.tiles.isEmpty {
                ZStack {
                    Color.black
                    Text("ストリーム未設定")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                tileGrid
            }
        }
        .background(Color.black)
        .overlay {
            if isChannelSelectorPresented, let channelCatalog {
                ChannelSelectorView(catalog: channelCatalog) { item in
                    model.playFocusedChannel(item.channel)
                    isChannelSelectorPresented = false
                } onCancel: {
                    isChannelSelectorPresented = false
                }
            }
        }
        .focusable()
        .onKeyPress { keyPress in
            handleKeyPress(keyPress.characters.lowercased())
        }
        .task {
            await channelCatalog?.loadIfNeeded()
        }
        .onAppear {
            model.focusInitialTileIfNeeded()
        }
    }

    private var tileGrid: some View {
        GeometryReader { proxy in
            let columns = Int(ceil(sqrt(Double(model.tiles.count))))
            let rows = Int(ceil(Double(model.tiles.count) / Double(columns)))
            let cellWidth = proxy.size.width / CGFloat(columns)
            let cellHeight = proxy.size.height / CGFloat(rows)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: 0), count: columns),
                spacing: 0
            ) {
                ForEach(Array(model.tiles.enumerated()), id: \.element.id) { index, tile in
                    TileView(model: tile, focused: model.focusedIndex == index) {
                        model.focus(index)
                    } onOpenChannelSelector: {
                        openChannelSelector()
                    }
                    .frame(width: cellWidth, height: cellHeight)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func handleKeyPress(_ characters: String) -> KeyPress.Result {
        guard !isChannelSelectorPresented else { return .ignored }
        guard model.tiles.indices.contains(model.focusedIndex) else { return .ignored }

        switch characters {
        case "s":
            model.setFocusedAudioMode(.stereo)
            return .handled
        case "l":
            model.setFocusedAudioMode(.left)
            return .handled
        case "r":
            model.setFocusedAudioMode(.right)
            return .handled
        case "c":
            openChannelSelector()
            return .handled
        default:
            return .ignored
        }
    }

    private func openChannelSelector() {
        guard channelCatalog != nil else { return }
        isChannelSelectorPresented = true
    }
}
