import Foundation
import Observation
import SwiftVLC

@MainActor
@Observable
final class TileGridModel {
    var focusedIndex = 0
    var tiles: [TileModel]
    var layout: TileLayoutConfig
    var settings: AppSettings
    var channelSettings: ChannelSettings
    var playbackModeOptions: [EPGStationLiveStreamModeOption]
    var volumePercent: Int
    var isSettingsPresented = false
    @ObservationIgnored var onLayoutChanged: ((TileLayoutConfig) -> Void)?
    @ObservationIgnored var onSettingsChanged: ((AppSettings) -> Void)?
    @ObservationIgnored var onSettingsPresentationChanged: ((Bool) -> Void)?
    private var config: AppConfig
    private let instance: VLCInstance
    private let audioOnlyFocusedTile: Bool
    private let epgStationClient: EPGStationClient?

    init(config: AppConfig, instance: VLCInstance, restoredState: AppState? = nil) {
        self.config = config
        self.instance = instance
        let initialSettings = (restoredState?.settings ?? .empty).fillingDefaults(from: config)
        self.settings = initialSettings
        self.channelSettings = (restoredState?.channelSettings ?? .empty).normalized
        self.playbackModeOptions = [
            EPGStationLiveStreamModeOption.fallback(mode: initialSettings.largeTilePlayback?.liveStreamMode ?? 0)
        ]
        let initialVolumePercent = VolumeLevel.normalized(initialSettings.volumePercent)
        self.volumePercent = initialVolumePercent
        var config = config
        config.volumePercent = initialVolumePercent
        self.config = config
        let initialStreams = initialSettings.startupStreams == .empty ? [] : config.streams
        let initialLayout = (restoredState?.tileLayout ?? config.tileLayout ?? .automatic(tileCount: max(initialStreams.count, 1)))
            .validOrFallback
            .fitting(streamCount: initialStreams.count)
        self.layout = initialLayout
        self.tiles = (0..<initialLayout.tileCount).map { index in
            TileModel(
                stream: initialStreams.indices.contains(index) ? initialStreams[index] : nil,
                config: config,
                instance: instance
            )
        }
        self.audioOnlyFocusedTile = config.audioOnlyFocusedTile ?? true
        self.epgStationClient = config.epgStationBaseURL.map { EPGStationClient(baseURL: $0) }
    }

    func focusInitialTileIfNeeded() {
        guard !tiles.isEmpty else { return }
        focus(0)
    }

    func focus(_ index: Int) {
        guard tiles.indices.contains(index) else { return }
        let targetIndex = promotedFocusIndex(for: index)
        applyFocus(targetIndex)
    }

    @discardableResult
    func swapTilesForDrag(sourceIndex: Int, targetIndex: Int) -> Bool {
        guard layout.canSwapTilesForDrag(sourceIndex: sourceIndex, targetIndex: targetIndex) else {
            return false
        }
        tiles.swapAt(sourceIndex, targetIndex)
        applyFocus(focusedIndex)
        return true
    }

    func canSwapTilesForDrag(sourceIndex: Int, targetIndex: Int?) -> Bool {
        guard let targetIndex else { return false }
        return layout.canSwapTilesForDrag(sourceIndex: sourceIndex, targetIndex: targetIndex)
    }

    private func applyFocus(_ index: Int) {
        guard tiles.indices.contains(index) else { return }
        focusedIndex = index
        guard audioOnlyFocusedTile else { return }

        for (tileIndex, tile) in tiles.enumerated() {
            tile.setMuted(tileIndex != index)
        }
    }

    private func promotedFocusIndex(for index: Int) -> Int {
        guard settings.keepFocusOnSingleLargeTile ?? true,
              let largeIndex = layout.singleLargeTileIndex,
              largeIndex != index,
              tiles.indices.contains(largeIndex)
        else {
            return index
        }
        if swapTiles(index, largeIndex, focusedIndexAfterSwap: nil) {
            applyPlaybackProfilesToTiles(at: [index, largeIndex], restartPolicy: .whenModeChanges)
            return largeIndex
        }
        return index
    }

    @discardableResult
    private func swapTiles(
        _ sourceIndex: Int,
        _ targetIndex: Int,
        focusedIndexAfterSwap: Int?
    ) -> Bool {
        guard sourceIndex != targetIndex,
              tiles.indices.contains(sourceIndex),
              tiles.indices.contains(targetIndex)
        else {
            return false
        }

        tiles.swapAt(sourceIndex, targetIndex)
        if let focusedIndexAfterSwap {
            applyFocus(focusedIndexAfterSwap)
        } else if focusedIndex == sourceIndex {
            focusedIndex = targetIndex
        } else if focusedIndex == targetIndex {
            focusedIndex = sourceIndex
        }
        return true
    }

    func setFocusedAudioSelection(_ selection: AudioSelection) {
        guard tiles.indices.contains(focusedIndex) else { return }
        guard tiles[focusedIndex].stream != nil else { return }
        tiles[focusedIndex].setAudioSelection(selection)
    }

    func toggleFocusedTileMuted() {
        guard tiles.indices.contains(focusedIndex) else { return }
        let tile = tiles[focusedIndex]
        guard tile.stream != nil else { return }
        tile.setMuted(!tile.isMuted)
    }

    func increaseVolume() {
        setVolumePercent(VolumeLevel.changed(from: volumePercent, by: VolumeLevel.step))
    }

    func decreaseVolume() {
        setVolumePercent(VolumeLevel.changed(from: volumePercent, by: -VolumeLevel.step))
    }

    func setVolumePercent(_ percent: Int) {
        let normalized = VolumeLevel.normalized(percent)
        guard volumePercent != normalized else { return }
        volumePercent = normalized
        settings.volumePercent = normalized
        config.volumePercent = normalized
        for tile in tiles {
            tile.setVolumePercent(normalized)
        }
        onSettingsChanged?(settings)
    }

    func playFocusedChannel(_ channel: EPGStationChannel) {
        playChannel(channel, at: focusedIndex, focusAfterPlay: true)
    }

    func playChannel(_ channel: EPGStationChannel, at index: Int, focusAfterPlay: Bool = false) {
        guard tiles.indices.contains(index), let epgStationClient else { return }

        let stream = streamConfig(
            channelID: channel.id,
            title: channel.name,
            tileIndex: index,
            epgStationClient: epgStationClient
        )
        tiles[index].play(stream: stream)
        if focusAfterPlay {
            focus(index)
        }
    }

    private func streamConfig(
        channelID: Int,
        title: String?,
        tileIndex: Int,
        epgStationClient: EPGStationClient
    ) -> StreamConfig {
        let profile = playbackProfile(for: tileIndex)
        let modeOption = playbackModeOption(for: profile.liveStreamMode)
        let url = epgStationClient.liveStreamURL(
            channelID: channelID,
            container: liveStreamContainer,
            mode: profile.liveStreamMode
        )
        return StreamConfig(
            channelID: channelID,
            playbackMode: profile.liveStreamMode,
            playbackModeName: modeOption?.name,
            isUnconvertedPlayback: modeOption?.isUnconverted,
            title: title,
            url: url.absoluteString,
            muted: nil,
            audioMode: nil,
            deinterlace: profile.deinterlaceForPlayback(isUnconverted: modeOption?.isUnconverted),
            mediaOptions: nil
        )
    }

    private func playbackProfile(for tileIndex: Int) -> TilePlaybackProfile {
        let isLargeTile = layout.placement(at: tileIndex)?.spansMultipleCells ?? false
        let fallback = config.defaultPlaybackProfile
        if isLargeTile {
            return settings.largeTilePlayback ?? config.largeTilePlayback ?? fallback
        }
        return settings.smallTilePlayback ?? config.smallTilePlayback ?? fallback
    }

    var liveStreamContainer: LiveStreamContainer {
        config.liveStreamContainer ?? .m2ts
    }

    func setPlaybackModeOptions(_ options: [EPGStationLiveStreamModeOption]) {
        let normalizedOptions = options.isEmpty ? [.fallback(mode: config.liveStreamMode ?? 0)] : options
        guard playbackModeOptions != normalizedOptions else { return }
        playbackModeOptions = normalizedOptions
        updatePlaybackMetadataForTiles()
    }

    func playbackModeOptions(including currentMode: Int) -> [EPGStationLiveStreamModeOption] {
        var options = playbackModeOptions
        if !options.contains(where: { $0.mode == currentMode }) {
            options.append(.fallback(mode: currentMode))
        }
        return options.sorted { $0.mode < $1.mode }
    }

    private func playbackModeOption(for mode: Int) -> EPGStationLiveStreamModeOption? {
        playbackModeOptions.first { $0.mode == mode }
    }

    func clearFocusedTile() {
        guard tiles.indices.contains(focusedIndex) else { return }
        tiles[focusedIndex].clear()
        focus(focusedIndex)
    }

    func reloadFocusedTile() {
        guard tiles.indices.contains(focusedIndex) else { return }
        tiles[focusedIndex].reload()
        focus(focusedIndex)
    }

    func presentSettings() {
        guard !isSettingsPresented else { return }
        isSettingsPresented = true
        onSettingsPresentationChanged?(true)
    }

    func dismissSettings() {
        guard isSettingsPresented else { return }
        isSettingsPresented = false
        onSettingsPresentationChanged?(false)
    }

    func increaseTileCapacity() {
        guard let nextLayout = layout.nextLarger else { return }
        applyTileLayout(nextLayout, focusFirstNewTile: true)
    }

    func decreaseTileCapacity() {
        guard let nextLayout = layout.nextSmaller else { return }
        applyTileLayout(nextLayout)
    }

    @discardableResult
    func applySettings(
        _ settings: AppSettings,
        tileLayout: TileLayoutConfig,
        channelSettings: ChannelSettings
    ) -> Bool {
        guard applyTileLayout(tileLayout) else { return false }
        let normalizedVolume = VolumeLevel.normalized(settings.volumePercent)
        var settings = settings
        settings.volumePercent = normalizedVolume
        settings.keepFocusOnSingleLargeTile = settings.keepFocusOnSingleLargeTile ?? true
        settings.largeTilePlayback = settings.largeTilePlayback
            ?? self.settings.largeTilePlayback
            ?? config.largeTilePlayback
            ?? config.defaultPlaybackProfile
        settings.smallTilePlayback = settings.smallTilePlayback
            ?? self.settings.smallTilePlayback
            ?? config.smallTilePlayback
            ?? config.defaultPlaybackProfile
        self.settings = settings
        self.channelSettings = channelSettings.normalized
        config = config.applying(settings)
        volumePercent = normalizedVolume
        for tile in tiles {
            tile.setVolumePercent(normalizedVolume)
        }
        applyPlaybackProfilesToTiles(restartPolicy: .whenPlaybackPipelineChanges)
        focus(focusedIndex)
        onSettingsChanged?(settings)
        return true
    }

    private enum PlaybackProfileRestartPolicy {
        case whenPlaybackPipelineChanges
        case whenModeChanges
        case never
    }

    private func applyPlaybackProfilesToTiles(restartPolicy: PlaybackProfileRestartPolicy) {
        applyPlaybackProfilesToTiles(at: Array(tiles.indices), restartPolicy: restartPolicy)
    }

    private func applyPlaybackProfilesToTiles(
        at indices: [Int],
        restartPolicy: PlaybackProfileRestartPolicy
    ) {
        guard let epgStationClient else { return }
        for index in indices where tiles.indices.contains(index) {
            guard let stream = tiles[index].stream, let channelID = stream.channelID else { continue }
            let updatedStream = streamConfig(
                channelID: channelID,
                title: stream.title,
                tileIndex: index,
                epgStationClient: epgStationClient
            )
            if shouldRestartPlayback(
                currentStream: stream,
                updatedStream: updatedStream,
                policy: restartPolicy
            ) {
                tiles[index].play(stream: updatedStream)
            } else {
                tiles[index].updateStreamMetadata(
                    metadataStream(
                        currentStream: stream,
                        updatedStream: updatedStream,
                        policy: restartPolicy
                    )
                )
            }
        }
    }

    private func updatePlaybackMetadataForTiles() {
        applyPlaybackProfilesToTiles(restartPolicy: .never)
    }

    private func shouldRestartPlayback(
        currentStream: StreamConfig,
        updatedStream: StreamConfig,
        policy: PlaybackProfileRestartPolicy
    ) -> Bool {
        switch policy {
        case .whenPlaybackPipelineChanges:
            return !currentStream.hasSamePlaybackPipeline(as: updatedStream)
        case .whenModeChanges:
            return currentStream.playbackMode != updatedStream.playbackMode
        case .never:
            return false
        }
    }

    private func metadataStream(
        currentStream: StreamConfig,
        updatedStream: StreamConfig,
        policy: PlaybackProfileRestartPolicy
    ) -> StreamConfig {
        guard policy == .whenModeChanges else { return updatedStream }
        var metadata = updatedStream
        metadata.deinterlace = currentStream.deinterlace
        return metadata
    }

    @discardableResult
    func applyTileLayout(_ newLayout: TileLayoutConfig, focusFirstNewTile: Bool = false) -> Bool {
        let newLayout = newLayout.validOrFallback
        let oldCount = tiles.count
        let newCount = newLayout.tileCount
        guard newCount > 0 else { return false }

        if newCount < oldCount {
            for tile in tiles.suffix(oldCount - newCount) {
                tile.clear()
            }
            tiles.removeLast(oldCount - newCount)
            focusedIndex = min(focusedIndex, tiles.count - 1)
        } else if newCount > oldCount {
            while tiles.count < newCount {
                tiles.append(TileModel(stream: nil, config: config, instance: instance))
            }
            if focusFirstNewTile {
                focusedIndex = oldCount
            }
        }

        layout = newLayout
        onLayoutChanged?(newLayout)
        focus(focusedIndex)
        return true
    }

    func shutdown() async {
        await withTaskGroup(of: Void.self) { group in
            for tile in tiles {
                group.addTask { await tile.shutdown() }
            }
        }
    }
}
