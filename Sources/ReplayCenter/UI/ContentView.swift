import SwiftUI

struct ContentView: View {
    @Bindable var model: TileGridModel
    @Bindable var windowChrome: WindowChromeModel
    let onChannelSelectorPresentationChanged: (Bool) -> Void
    let onContentWindowDragChanged: () -> Void
    let onContentWindowDragEnded: () -> Void
    @State private var isChannelSelectorPresented = false
    @State private var channelSelectionTargetIndex: Int?
    @State private var draggingTileIndex: Int?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragTargetIndex: Int?
    @FocusState private var isKeyboardFocused: Bool

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
        .background(Color.clear)
        .ignoresSafeArea(.container, edges: .top)
        .overlay {
            if isChannelSelectorPresented, let channelCatalog = model.channelCatalog {
                ChannelSelectorView(
                    catalog: channelCatalog,
                    channelSettings: model.channelSettings,
                    programGenreDisplaySettings: model.settings.programGenreDisplaySettings ?? .preset
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
                SettingsView(
                    model: model,
                    requiresEPGStationConnection: model.isEPGStationSetupRequired
                ) {
                    model.dismissSettings()
                }
            }
        }
        .focusable()
        .focused($isKeyboardFocused)
        .focusEffectDisabled()
        .onKeyPress { keyPress in
            handleKeyPress(keyPress)
        }
        .task {
            await model.channelCatalog?.loadIfNeeded()
            updatePlaybackModeOptionsFromCatalog()
            model.refreshFocusedWindowTitle()
            await refreshCurrentProgramsPeriodically()
        }
        .onAppear {
            model.focusInitialTileIfNeeded()
            model.onFocusedChannelSelectionRequested = {
                openChannelSelector(for: model.focusedIndex)
            }
            isKeyboardFocused = true
        }
        .onDisappear {
            model.onFocusedChannelSelectionRequested = nil
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
                if let draggingTileIndex,
                   let placement = model.layout.placement(at: draggingTileIndex)
                {
                    EmptyTilePanelBackground(isHovering: false)
                        .overlay {
                            EmptyTilePanelStroke(isHovering: false)
                        }
                        .frame(
                            width: cellWidth * CGFloat(placement.width),
                            height: cellHeight * CGFloat(placement.height)
                        )
                        .position(
                            x: cellWidth * (CGFloat(placement.x) + CGFloat(placement.width) / 2),
                            y: cellHeight * (CGFloat(placement.y) + CGFloat(placement.height) / 2)
                        )
                }

                ForEach(Array(model.tiles.enumerated()), id: \.element.id) { index, tile in
                    if let placement = model.layout.placement(at: index) {
                        let isDragging = draggingTileIndex == index
                        let topOverlayInset = topOverlayInset(
                            for: placement,
                            gridSize: gridSize,
                            availableSize: proxy.size
                        )
                        TileView(
                            model: tile,
                            focused: model.focusedIndex == index,
                            dropTarget: dragTargetIndex == index,
                            volumePercent: tile.volumePercent,
                            showStreamInfo: model.settings.showStreamInfoOverlay ?? false,
                            showFocusRing: windowChrome.isHovering,
                            hoverInteractionsActive: windowChrome.areHoverInteractionsActive,
                            topOverlayInset: topOverlayInset,
                            channelProgramInfo: model.channelProgramOverlayInfo(for: tile),
                            channelProgramOverlayVisibility: model.settings.channelProgramOverlayVisibility ?? .onHover
                        ) {
                            if tile.stream != nil {
                                model.focus(index)
                            }
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
                            model.clearTile(at: index)
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

    private func topOverlayInset(
        for placement: TilePlacement,
        gridSize: CGSize,
        availableSize: CGSize
    ) -> CGFloat {
        guard placement.y == 0 else { return 0 }
        let topLetterboxHeight = max((availableSize.height - gridSize.height) / 2, 0)
        return max(windowChrome.topOverlayChromeHeight - topLetterboxHeight, 0)
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
                if model.layout.tileCount == 1 {
                    onContentWindowDragChanged()
                    return
                }
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
                if model.layout.tileCount == 1 {
                    onContentWindowDragEnded()
                    return
                }
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

        if keyPress.key == .delete {
            model.clearFocusedTile()
            return .handled
        }

        let characters = keyPress.characters.lowercased()
        if characters == "\u{7f}" {
            model.clearFocusedTile()
            return .handled
        }

        switch characters {
        case "c":
            model.requestFocusedChannelSelection()
            return .handled
        case "m":
            model.toggleFocusedTileMuted()
            return .handled
        case "[":
            model.decreaseVolume()
            return .handled
        case "]":
            model.increaseVolume()
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
        isKeyboardFocused = false
        Task { @MainActor in
            await Task.yield()
            isKeyboardFocused = true
        }
    }

    private func updatePlaybackModeOptionsFromCatalog() {
        guard let channelCatalog = model.channelCatalog else { return }
        model.setPlaybackModeOptions(channelCatalog.playbackModeOptions(for: model.liveStreamContainer))
    }

    private func refreshCurrentProgramsPeriodically() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                return
            }
            await model.refreshCurrentPrograms()
        }
    }
}
