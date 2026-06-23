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
    var isSettingsPresented = false
    @ObservationIgnored var onLayoutChanged: ((TileLayoutConfig) -> Void)?
    @ObservationIgnored var onSettingsChanged: ((AppSettings) -> Void)?
    private var config: AppConfig
    private let instance: VLCInstance
    private let audioOnlyFocusedTile: Bool
    private let epgStationClient: EPGStationClient?

    init(config: AppConfig, instance: VLCInstance, restoredState: AppState? = nil) {
        self.config = config
        self.instance = instance
        let initialSettings = (restoredState?.settings ?? .empty).fillingDefaults(from: config)
        self.settings = initialSettings
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
        focusedIndex = index
        guard audioOnlyFocusedTile else { return }

        for (tileIndex, tile) in tiles.enumerated() {
            tile.setMuted(tileIndex != index)
        }
    }

    func setFocusedAudioMode(_ mode: AudioMode) {
        guard tiles.indices.contains(focusedIndex) else { return }
        guard tiles[focusedIndex].stream != nil else { return }
        tiles[focusedIndex].setAudioMode(mode)
    }

    func playFocusedChannel(_ channel: EPGStationChannel) {
        guard tiles.indices.contains(focusedIndex), let epgStationClient else { return }

        let url = epgStationClient.liveStreamURL(
            channelID: channel.id,
            container: config.liveStreamContainer ?? .m2ts,
            mode: config.liveStreamMode ?? 0
        )
        let stream = StreamConfig(
            title: channel.name,
            url: url.absoluteString,
            muted: nil,
            audioMode: nil,
            deinterlace: nil,
            mediaOptions: nil
        )
        tiles[focusedIndex].play(stream: stream)
        focus(focusedIndex)
    }

    func clearFocusedTile() {
        guard tiles.indices.contains(focusedIndex) else { return }
        tiles[focusedIndex].clear()
        focus(focusedIndex)
    }

    func presentSettings() {
        isSettingsPresented = true
    }

    func dismissSettings() {
        isSettingsPresented = false
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
    func applySettings(_ settings: AppSettings, tileLayout: TileLayoutConfig) -> Bool {
        guard applyTileLayout(tileLayout) else { return false }
        self.settings = settings
        config = config.applying(settings)
        onSettingsChanged?(settings)
        return true
    }

    @discardableResult
    func applyTileLayout(_ newLayout: TileLayoutConfig, focusFirstNewTile: Bool = false) -> Bool {
        let newLayout = newLayout.validOrFallback
        let oldCount = tiles.count
        let newCount = newLayout.tileCount
        guard newCount > 0 else { return false }

        if newCount < oldCount {
            let removedTiles = tiles.suffix(oldCount - newCount)
            guard removedTiles.allSatisfy({ $0.stream == nil }) else {
                fputs("[app] cannot shrink tile layout; clear trailing tiles first\n", stderr)
                return false
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
