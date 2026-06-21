import Foundation
import Observation
import SwiftVLC

@MainActor
@Observable
final class TileGridModel {
    var focusedIndex = 0
    var tiles: [TileModel]
    var layout: TileLayoutConfig
    @ObservationIgnored var onLayoutChanged: ((TileLayoutConfig) -> Void)?
    private let config: AppConfig
    private let instance: VLCInstance
    private let audioOnlyFocusedTile: Bool
    private let epgStationClient: EPGStationClient?

    init(config: AppConfig, instance: VLCInstance) {
        self.config = config
        self.instance = instance
        let initialLayout = (config.tileLayout ?? .automatic(tileCount: max(config.streams.count, 1)))
            .validOrFallback
            .fitting(streamCount: config.streams.count)
        self.layout = initialLayout
        self.tiles = (0..<initialLayout.tileCount).map { index in
            TileModel(
                stream: config.streams.indices.contains(index) ? config.streams[index] : nil,
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

    func increaseTileCapacity() {
        guard let nextLayout = layout.nextLarger else { return }
        let firstNewIndex = tiles.count
        while tiles.count < nextLayout.tileCount {
            tiles.append(TileModel(stream: nil, config: config, instance: instance))
        }
        layout = nextLayout
        onLayoutChanged?(nextLayout)
        focus(firstNewIndex)
    }

    func decreaseTileCapacity() {
        guard let nextLayout = layout.nextSmaller else { return }
        guard nextLayout.tileCount < tiles.count else { return }
        guard tiles[nextLayout.tileCount...].allSatisfy({ $0.stream == nil }) else {
            fputs("[app] cannot shrink tile layout; clear trailing tiles first\n", stderr)
            return
        }
        tiles.removeLast(tiles.count - nextLayout.tileCount)
        layout = nextLayout
        focusedIndex = min(focusedIndex, tiles.count - 1)
        onLayoutChanged?(nextLayout)
        focus(focusedIndex)
    }

    func shutdown() async {
        await withTaskGroup(of: Void.self) { group in
            for tile in tiles {
                group.addTask { await tile.shutdown() }
            }
        }
    }
}
