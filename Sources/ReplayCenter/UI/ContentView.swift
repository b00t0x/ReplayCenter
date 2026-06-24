import SwiftUI

struct ContentView: View {
    @Bindable var model: TileGridModel
    let channelCatalog: ChannelCatalogModel?
    let onChannelSelectorPresentationChanged: (Bool) -> Void
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
                ChannelSelectorView(
                    catalog: channelCatalog,
                    channelSettings: model.channelSettings
                ) { item in
                    model.playFocusedChannel(item.channel)
                    closeChannelSelector()
                } onCancel: {
                    closeChannelSelector()
                }
            }
        }
        .overlay {
            if model.isSettingsPresented {
                SettingsView(model: model, channelCatalog: channelCatalog) {
                    model.dismissSettings()
                }
            }
        }
        .focusable()
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
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
            let columns = model.layout.columns
            let rows = model.layout.rows
            let gridSize = fittedGridSize(in: proxy.size)
            let cellWidth = gridSize.width / CGFloat(columns)
            let cellHeight = gridSize.height / CGFloat(rows)

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
            .frame(width: gridSize.width, height: gridSize.height, alignment: .topLeading)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
    }

    private func fittedGridSize(in availableSize: CGSize) -> CGSize {
        guard availableSize.width > 0, availableSize.height > 0 else { return .zero }
        let aspect = model.layout.gridAspectRatio.width / model.layout.gridAspectRatio.height
        let availableAspect = availableSize.width / availableSize.height

        if availableAspect > aspect {
            return CGSize(width: availableSize.height * aspect, height: availableSize.height)
        } else {
            return CGSize(width: availableSize.width, height: availableSize.width / aspect)
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        guard !isChannelSelectorPresented, !model.isSettingsPresented else { return .ignored }
        guard model.tiles.indices.contains(model.focusedIndex) else { return .ignored }

        if keyPress.key == .delete || keyPress.key == .deleteForward {
            model.clearFocusedTile()
            return .handled
        }

        let characters = keyPress.characters.lowercased()
        if characters == "\u{7f}" || characters == "\u{8}" {
            model.clearFocusedTile()
            return .handled
        }

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
        case ",":
            model.presentSettings()
            return .handled
        case "+", "=":
            model.increaseTileCapacity()
            return .handled
        case "-":
            model.decreaseTileCapacity()
            return .handled
        default:
            return .ignored
        }
    }

    private func openChannelSelector() {
        guard channelCatalog != nil else { return }
        guard !isChannelSelectorPresented else { return }
        isChannelSelectorPresented = true
        onChannelSelectorPresentationChanged(true)
    }

    private func closeChannelSelector() {
        guard isChannelSelectorPresented else { return }
        isChannelSelectorPresented = false
        onChannelSelectorPresentationChanged(false)
    }
}
