import SwiftUI

struct ContentView: View {
    @Bindable var model: TileGridModel
    let onChannelSelectorPresentationChanged: (Bool) -> Void
    @State private var isChannelSelectorPresented = false
    @State private var channelSelectionTargetIndex: Int?
    @State private var draggingTileIndex: Int?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragTargetIndex: Int?

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
            if isChannelSelectorPresented, let channelCatalog = model.channelCatalog {
                ChannelSelectorView(
                    catalog: channelCatalog,
                    channelSettings: model.channelSettings
                ) { item in
                    updatePlaybackModeOptionsFromCatalog()
                    model.playChannel(
                        item,
                        at: channelSelectionTargetIndex ?? model.focusedIndex
                    )
                    closeChannelSelector()
                } onCancel: {
                    closeChannelSelector()
                }
            }
        }
        .overlay {
            if model.isSettingsPresented {
                SettingsView(model: model) {
                    model.dismissSettings()
                }
            }
        }
        .focusable()
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .task {
            await model.channelCatalog?.loadIfNeeded()
            updatePlaybackModeOptionsFromCatalog()
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

            ZStack(alignment: .topLeading) {
                ForEach(Array(model.tiles.enumerated()), id: \.element.id) { index, tile in
                    if let placement = model.layout.placement(at: index) {
                        let isDragging = draggingTileIndex == index
                        TileView(
                            model: tile,
                            focused: model.focusedIndex == index,
                            dropTarget: dragTargetIndex == index,
                            volumePercent: model.volumePercent,
                            showStreamInfo: model.settings.showStreamInfoOverlay ?? true
                        ) {
                            model.focus(index)
                        } onOpenChannelSelector: {
                            openChannelSelector(for: index)
                        } onSetAudioSelection: { selection in
                            model.setFocusedAudioSelection(selection)
                        } onToggleMuted: {
                            model.toggleFocusedTileMuted()
                        } onDecreaseVolume: {
                            model.decreaseVolume()
                        } onIncreaseVolume: {
                            model.increaseVolume()
                        } onReload: {
                            model.reloadFocusedTile()
                        } onClear: {
                            model.clearFocusedTile()
                        }
                        .frame(
                            width: cellWidth * CGFloat(placement.width),
                            height: cellHeight * CGFloat(placement.height)
                        )
                        .position(
                            x: cellWidth * (CGFloat(placement.x) + CGFloat(placement.width) / 2),
                            y: cellHeight * (CGFloat(placement.y) + CGFloat(placement.height) / 2)
                        )
                        .offset(isDragging ? dragTranslation : .zero)
                        .scaleEffect(isDragging ? 1.015 : 1)
                        .shadow(color: isDragging ? .black.opacity(0.45) : .clear, radius: 14)
                        .zIndex(tileZIndex(index: index, isDragging: isDragging))
                        .highPriorityGesture(
                            tileDragGesture(
                                sourceIndex: index,
                                sourcePlacement: placement,
                                cellWidth: cellWidth,
                                cellHeight: cellHeight
                            )
                        )
                    }
                }

                if draggingTileIndex != nil {
                    Color.black.opacity(0.54)
                        .allowsHitTesting(false)
                        .zIndex(8)
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

    private func tileZIndex(index: Int, isDragging: Bool) -> Double {
        if isDragging {
            return 10
        }
        if dragTargetIndex == index {
            return 9
        }
        if model.focusedIndex == index {
            return 1
        }
        return 0
    }

    private func tileDragGesture(
        sourceIndex: Int,
        sourcePlacement: TilePlacement,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isChannelSelectorPresented, !model.isSettingsPresented else { return }
                draggingTileIndex = sourceIndex
                dragTranslation = value.translation
                dragTargetIndex = dropTargetIndex(
                    sourceIndex: sourceIndex,
                    sourcePlacement: sourcePlacement,
                    translation: value.translation,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight
                )
            }
            .onEnded { value in
                defer { resetDragState() }
                guard !isChannelSelectorPresented, !model.isSettingsPresented else { return }
                guard let targetIndex = dropTargetIndex(
                    sourceIndex: sourceIndex,
                    sourcePlacement: sourcePlacement,
                    translation: value.translation,
                    cellWidth: cellWidth,
                    cellHeight: cellHeight
                ) else {
                    return
                }
                model.swapTilesForDrag(sourceIndex: sourceIndex, targetIndex: targetIndex)
            }
    }

    private func dropTargetIndex(
        sourceIndex: Int,
        sourcePlacement: TilePlacement,
        translation: CGSize,
        cellWidth: CGFloat,
        cellHeight: CGFloat
    ) -> Int? {
        guard cellWidth > 0, cellHeight > 0 else { return nil }
        let centerX = cellWidth * (CGFloat(sourcePlacement.x) + CGFloat(sourcePlacement.width) / 2)
            + translation.width
        let centerY = cellHeight * (CGFloat(sourcePlacement.y) + CGFloat(sourcePlacement.height) / 2)
            + translation.height
        guard centerX >= 0, centerY >= 0 else { return nil }
        let cellX = Int(centerX / cellWidth)
        let cellY = Int(centerY / cellHeight)
        let targetIndex = model.layout.placements.indices.first { index in
            let placement = model.layout.placements[index]
            return cellX >= placement.x
                && cellX < placement.maxX
                && cellY >= placement.y
                && cellY < placement.maxY
        }
        guard model.canSwapTilesForDrag(sourceIndex: sourceIndex, targetIndex: targetIndex) else {
            return nil
        }
        return targetIndex
    }

    private func resetDragState() {
        draggingTileIndex = nil
        dragTranslation = .zero
        dragTargetIndex = nil
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
        case "l":
            model.setFocusedAudioSelection(.primary)
            return .handled
        case "r":
            model.setFocusedAudioSelection(.secondary)
            return .handled
        case "c":
            openChannelSelector(for: model.focusedIndex)
            return .handled
        case ",":
            model.presentSettings()
            return .handled
        case "[":
            model.decreaseVolume()
            return .handled
        case "]":
            model.increaseVolume()
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

    private func openChannelSelector(for index: Int) {
        guard let channelCatalog = model.channelCatalog else { return }
        guard !isChannelSelectorPresented else { return }
        channelSelectionTargetIndex = model.tiles.indices.contains(index) ? index : model.focusedIndex
        isChannelSelectorPresented = true
        onChannelSelectorPresentationChanged(true)
        Task {
            await channelCatalog.loadIfNeeded()
            updatePlaybackModeOptionsFromCatalog()
        }
    }

    private func closeChannelSelector() {
        guard isChannelSelectorPresented else { return }
        isChannelSelectorPresented = false
        channelSelectionTargetIndex = nil
        onChannelSelectorPresentationChanged(false)
    }

    private func updatePlaybackModeOptionsFromCatalog() {
        guard let channelCatalog = model.channelCatalog else { return }
        model.setPlaybackModeOptions(channelCatalog.playbackModeOptions(for: model.liveStreamContainer))
    }
}
