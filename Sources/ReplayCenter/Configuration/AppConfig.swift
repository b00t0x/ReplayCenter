import Foundation

struct AppConfig: Decodable {
    var windowTitle: String?
    var epgStationBaseURL: URL?
    var liveStreamContainer: LiveStreamContainer?
    var liveStreamMode: Int?
    var vlcArguments: [String]?
    var networkCachingMs: Int?
    var deinterlace: String?
    var mediaOptions: [String]?
    var dualMonoFilter: DualMonoFilterConfig?
    var volumePercent: Int?
    var audioOnlyFocusedTile: Bool?
    var startMuted: Bool?
    var audioMode: AudioMode?
    var tileLayout: TileLayoutConfig?
    var startupStreams: StartupStreamsMode?
    var keepFocusOnSingleLargeTile: Bool?
    var largeTilePlayback: TilePlaybackProfile?
    var smallTilePlayback: TilePlaybackProfile?
    var streams: [StreamConfig]

    static let empty = AppConfig(
        windowTitle: "ReplayCenter",
        epgStationBaseURL: nil,
        liveStreamContainer: .m2ts,
        liveStreamMode: 0,
        vlcArguments: [],
        networkCachingMs: 1000,
        deinterlace: "yadif",
        mediaOptions: [],
        dualMonoFilter: .default,
        volumePercent: 100,
        audioOnlyFocusedTile: true,
        startMuted: true,
        audioMode: .stereo,
        tileLayout: nil,
        startupStreams: .configured,
        keepFocusOnSingleLargeTile: true,
        largeTilePlayback: nil,
        smallTilePlayback: nil,
        streams: []
    )

    var effectiveDeinterlaceLabel: String {
        let value = deinterlace?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : "<unchanged>"
    }

    var summary: String {
        [
            "streams=\(streams.count)",
            "epgStationBaseURL=\(epgStationBaseURL?.absoluteString ?? "<nil>")",
            "liveStreamContainer=\(liveStreamContainer?.rawValue ?? "<nil>")",
            "liveStreamMode=\(liveStreamMode.map(String.init) ?? "<nil>")",
            "deinterlace=\(effectiveDeinterlaceLabel)",
            "networkCachingMs=\(networkCachingMs.map(String.init) ?? "<nil>")",
            "volumePercent=\(volumePercent.map(String.init) ?? "<nil>")",
            "audioOnlyFocusedTile=\(audioOnlyFocusedTile.map(String.init) ?? "<nil>")",
            "startMuted=\(startMuted.map(String.init) ?? "<nil>")",
            "audioMode=\(audioMode?.rawValue ?? "<nil>")",
            "tileLayout=\(tileLayout?.summary ?? "<auto>")",
            "startupStreams=\(startupStreams?.rawValue ?? "<nil>")",
            "keepFocusOnSingleLargeTile=\(keepFocusOnSingleLargeTile.map(String.init) ?? "<nil>")",
            "largeTilePlayback=\((largeTilePlayback ?? defaultPlaybackProfile).summary)",
            "smallTilePlayback=\((smallTilePlayback ?? defaultPlaybackProfile).summary)",
            "dualMonoFilter=\((dualMonoFilter ?? .default).summary)",
            "vlcArguments=\(vlcArguments ?? [])",
            "mediaOptions=\(mediaOptions ?? [])"
        ].joined(separator: " ")
    }

    var defaultPlaybackProfile: TilePlaybackProfile {
        TilePlaybackProfile(
            liveStreamMode: liveStreamMode ?? 0,
            deinterlace: effectiveDeinterlaceLabel
        )
    }
}

struct AppSettings: Codable, Equatable {
    var epgStationBaseURL: URL?
    var volumePercent: Int?
    var keepFocusOnSingleLargeTile: Bool?
    var showStreamInfoOverlay: Bool?
    var largeTilePlayback: TilePlaybackProfile?
    var smallTilePlayback: TilePlaybackProfile?

    private enum CodingKeys: String, CodingKey {
        case epgStationBaseURL
        case volumePercent
        case keepFocusOnSingleLargeTile
        case showStreamInfoOverlay
        case showInputClockOverlay
        case largeTilePlayback
        case smallTilePlayback
    }

    init(
        epgStationBaseURL: URL?,
        volumePercent: Int?,
        keepFocusOnSingleLargeTile: Bool?,
        showStreamInfoOverlay: Bool?,
        largeTilePlayback: TilePlaybackProfile?,
        smallTilePlayback: TilePlaybackProfile?
    ) {
        self.epgStationBaseURL = epgStationBaseURL
        self.volumePercent = volumePercent
        self.keepFocusOnSingleLargeTile = keepFocusOnSingleLargeTile
        self.showStreamInfoOverlay = showStreamInfoOverlay
        self.largeTilePlayback = largeTilePlayback
        self.smallTilePlayback = smallTilePlayback
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epgStationBaseURL = try container.decodeIfPresent(URL.self, forKey: .epgStationBaseURL)
        volumePercent = try container.decodeIfPresent(Int.self, forKey: .volumePercent)
        keepFocusOnSingleLargeTile = try container.decodeIfPresent(Bool.self, forKey: .keepFocusOnSingleLargeTile)
        showStreamInfoOverlay = try container.decodeIfPresent(Bool.self, forKey: .showStreamInfoOverlay)
            ?? container.decodeIfPresent(Bool.self, forKey: .showInputClockOverlay)
        largeTilePlayback = try container.decodeIfPresent(TilePlaybackProfile.self, forKey: .largeTilePlayback)
        smallTilePlayback = try container.decodeIfPresent(TilePlaybackProfile.self, forKey: .smallTilePlayback)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(epgStationBaseURL, forKey: .epgStationBaseURL)
        try container.encodeIfPresent(volumePercent, forKey: .volumePercent)
        try container.encodeIfPresent(keepFocusOnSingleLargeTile, forKey: .keepFocusOnSingleLargeTile)
        try container.encodeIfPresent(showStreamInfoOverlay, forKey: .showStreamInfoOverlay)
        try container.encodeIfPresent(largeTilePlayback, forKey: .largeTilePlayback)
        try container.encodeIfPresent(smallTilePlayback, forKey: .smallTilePlayback)
    }

    static let empty = AppSettings(
        epgStationBaseURL: nil,
        volumePercent: nil,
        keepFocusOnSingleLargeTile: nil,
        showStreamInfoOverlay: nil,
        largeTilePlayback: nil,
        smallTilePlayback: nil
    )

    static func defaults(from config: AppConfig) -> AppSettings {
        AppSettings(
            epgStationBaseURL: config.epgStationBaseURL,
            volumePercent: VolumeLevel.normalized(config.volumePercent),
            keepFocusOnSingleLargeTile: config.keepFocusOnSingleLargeTile ?? true,
            showStreamInfoOverlay: true,
            largeTilePlayback: config.largeTilePlayback ?? config.defaultPlaybackProfile,
            smallTilePlayback: config.smallTilePlayback ?? config.defaultPlaybackProfile
        )
    }

    func fillingDefaults(from config: AppConfig) -> AppSettings {
        let defaultPlaybackProfile = config.defaultPlaybackProfile
        return AppSettings(
            epgStationBaseURL: epgStationBaseURL ?? config.epgStationBaseURL,
            volumePercent: VolumeLevel.normalized(volumePercent ?? config.volumePercent),
            keepFocusOnSingleLargeTile: keepFocusOnSingleLargeTile
                ?? config.keepFocusOnSingleLargeTile
                ?? true,
            showStreamInfoOverlay: showStreamInfoOverlay ?? true,
            largeTilePlayback: largeTilePlayback
                ?? config.largeTilePlayback
                ?? defaultPlaybackProfile,
            smallTilePlayback: smallTilePlayback
                ?? config.smallTilePlayback
                ?? defaultPlaybackProfile
        )
    }

    var summary: String {
        [
            "epgStationBaseURL=\(epgStationBaseURL?.absoluteString ?? "<nil>")",
            "volumePercent=\(volumePercent.map(String.init) ?? "<nil>")",
            "keepFocusOnSingleLargeTile=\(keepFocusOnSingleLargeTile.map(String.init) ?? "<nil>")",
            "showStreamInfoOverlay=\(showStreamInfoOverlay.map(String.init) ?? "<nil>")",
            "largeTilePlayback=\(largeTilePlayback?.summary ?? "<nil>")",
            "smallTilePlayback=\(smallTilePlayback?.summary ?? "<nil>")"
        ].joined(separator: " ")
    }
}

extension AppConfig {
    func applying(_ settings: AppSettings?) -> AppConfig {
        guard let settings else { return self }
        var config = self
        config.epgStationBaseURL = settings.epgStationBaseURL
        if let volumePercent = settings.volumePercent {
            config.volumePercent = VolumeLevel.normalized(volumePercent)
        }
        if let keepFocusOnSingleLargeTile = settings.keepFocusOnSingleLargeTile {
            config.keepFocusOnSingleLargeTile = keepFocusOnSingleLargeTile
        }
        if let largeTilePlayback = settings.largeTilePlayback {
            config.largeTilePlayback = largeTilePlayback
        }
        if let smallTilePlayback = settings.smallTilePlayback {
            config.smallTilePlayback = smallTilePlayback
        }
        return config
    }
}

struct TilePlaybackProfile: Codable, Equatable, Hashable {
    var liveStreamMode: Int
    var deinterlace: String

    static let fallback = TilePlaybackProfile(liveStreamMode: 0, deinterlace: "yadif")

    var summary: String {
        "mode=\(liveStreamMode),deinterlace=\(deinterlace)"
    }

    var deinterlaceForPlayback: String {
        deinterlaceForPlayback(isUnconverted: nil)
    }

    func deinterlaceForPlayback(isUnconverted: Bool?) -> String {
        isUnconverted == true ? deinterlace : "off"
    }
}

enum VolumeLevel {
    static let minimum = 0
    static let maximum = 100
    static let step = 5

    static func normalized(_ value: Int?) -> Int {
        guard let value else { return maximum }
        let clamped = min(max(value, minimum), maximum)
        return min(maximum, ((clamped + step / 2) / step) * step)
    }

    static func changed(from value: Int, by delta: Int) -> Int {
        normalized(value + delta)
    }
}

struct DualMonoFilterConfig: Codable, Equatable {
    var filterPath: String?
    var muxSelectedToStereo: Bool?

    static let `default` = DualMonoFilterConfig(
        filterPath: nil,
        muxSelectedToStereo: false
    )

    var effectiveMuxSelectedToStereo: Bool {
        muxSelectedToStereo ?? false
    }

    var summary: String {
        [
            "filterPath=\(filterPath ?? "<auto>")",
            "muxSelectedToStereo=\(effectiveMuxSelectedToStereo)"
        ].joined(separator: ",")
    }
}

enum StartupStreamsMode: String, Codable, Hashable {
    case configured
    case empty
}

struct TilePlacement: Codable, Equatable, Hashable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int

    var maxX: Int { x + width }
    var maxY: Int { y + height }
    var spansMultipleCells: Bool { width > 1 || height > 1 }

    func hasSameSize(as other: TilePlacement) -> Bool {
        width == other.width && height == other.height
    }
}

struct TileLayoutConfig: Codable, Equatable, Hashable {
    let columns: Int
    let rows: Int
    let placements: [TilePlacement]
    let label: String?

    static let fallback = TileLayoutConfig(columns: 1, rows: 1)
    static let standardPresets = [
        TileLayoutConfig(columns: 2, rows: 1),
        TileLayoutConfig(columns: 2, rows: 2),
        TileLayoutConfig(columns: 3, rows: 2),
        TileLayoutConfig(columns: 2, rows: 3),
        TileLayoutConfig(columns: 3, rows: 3)
    ]
    static let wideTallPresets = [
        TileLayoutConfig(columns: 3, rows: 1),
        TileLayoutConfig(columns: 4, rows: 1),
        TileLayoutConfig(columns: 5, rows: 1),
        TileLayoutConfig(columns: 6, rows: 1),
        TileLayoutConfig(columns: 1, rows: 3),
        TileLayoutConfig(columns: 1, rows: 4),
        TileLayoutConfig(columns: 1, rows: 5),
        TileLayoutConfig(columns: 1, rows: 6),
        TileLayoutConfig(columns: 4, rows: 2),
        TileLayoutConfig(columns: 2, rows: 4)
    ]
    static let largePresets = [
        TileLayoutConfig(columns: 1, rows: 1),
        TileLayoutConfig.large(
            columns: 3,
            rows: 2,
            largeTiles: [TilePlacement(x: 0, y: 0, width: 2, height: 2)],
            label: "3x2 大左"
        ),
        TileLayoutConfig.large(
            columns: 3,
            rows: 2,
            largeTiles: [TilePlacement(x: 1, y: 0, width: 2, height: 2)],
            label: "3x2 大右"
        ),
        TileLayoutConfig.large(
            columns: 2,
            rows: 3,
            largeTiles: [TilePlacement(x: 0, y: 0, width: 2, height: 2)],
            label: "2x3 大上"
        ),
        TileLayoutConfig.large(
            columns: 2,
            rows: 3,
            largeTiles: [TilePlacement(x: 0, y: 1, width: 2, height: 2)],
            label: "2x3 大下"
        ),
        TileLayoutConfig.large(
            columns: 3,
            rows: 3,
            largeTiles: [TilePlacement(x: 0, y: 0, width: 2, height: 2)],
            label: "3x3 大左上"
        ),
        TileLayoutConfig.large(
            columns: 3,
            rows: 3,
            largeTiles: [TilePlacement(x: 1, y: 0, width: 2, height: 2)],
            label: "3x3 大右上"
        ),
        TileLayoutConfig.large(
            columns: 3,
            rows: 3,
            largeTiles: [TilePlacement(x: 0, y: 1, width: 2, height: 2)],
            label: "3x3 大左下"
        ),
        TileLayoutConfig.large(
            columns: 3,
            rows: 3,
            largeTiles: [TilePlacement(x: 1, y: 1, width: 2, height: 2)],
            label: "3x3 大右下"
        ),
        TileLayoutConfig.large(
            columns: 4,
            rows: 2,
            largeTiles: [TilePlacement(x: 0, y: 0, width: 2, height: 2)],
            label: "4x2 大左"
        ),
        TileLayoutConfig.large(
            columns: 4,
            rows: 2,
            largeTiles: [TilePlacement(x: 1, y: 0, width: 2, height: 2)],
            label: "4x2 大中"
        ),
        TileLayoutConfig.large(
            columns: 4,
            rows: 2,
            largeTiles: [TilePlacement(x: 2, y: 0, width: 2, height: 2)],
            label: "4x2 大右"
        ),
        TileLayoutConfig.large(
            columns: 2,
            rows: 4,
            largeTiles: [TilePlacement(x: 0, y: 0, width: 2, height: 2)],
            label: "2x4 大上"
        ),
        TileLayoutConfig.large(
            columns: 2,
            rows: 4,
            largeTiles: [TilePlacement(x: 0, y: 1, width: 2, height: 2)],
            label: "2x4 大中"
        ),
        TileLayoutConfig.large(
            columns: 2,
            rows: 4,
            largeTiles: [TilePlacement(x: 0, y: 2, width: 2, height: 2)],
            label: "2x4 大下"
        ),
        TileLayoutConfig.large(
            columns: 4,
            rows: 4,
            largeTiles: [
                TilePlacement(x: 2, y: 0, width: 2, height: 2),
                TilePlacement(x: 0, y: 2, width: 2, height: 2),
                TilePlacement(x: 2, y: 2, width: 2, height: 2)
            ],
            label: "4x4 大3 左上小"
        ),
        TileLayoutConfig.large(
            columns: 4,
            rows: 4,
            largeTiles: [
                TilePlacement(x: 0, y: 0, width: 2, height: 2),
                TilePlacement(x: 0, y: 2, width: 2, height: 2),
                TilePlacement(x: 2, y: 2, width: 2, height: 2)
            ],
            label: "4x4 大3 右上小"
        ),
        TileLayoutConfig.large(
            columns: 4,
            rows: 4,
            largeTiles: [
                TilePlacement(x: 0, y: 0, width: 2, height: 2),
                TilePlacement(x: 2, y: 0, width: 2, height: 2),
                TilePlacement(x: 2, y: 2, width: 2, height: 2)
            ],
            label: "4x4 大3 左下小"
        ),
        TileLayoutConfig.large(
            columns: 4,
            rows: 4,
            largeTiles: [
                TilePlacement(x: 0, y: 0, width: 2, height: 2),
                TilePlacement(x: 2, y: 0, width: 2, height: 2),
                TilePlacement(x: 0, y: 2, width: 2, height: 2)
            ],
            label: "4x4 大3 右下小"
        )
    ]
    static let presets = standardPresets

    init(
        columns: Int,
        rows: Int,
        placements: [TilePlacement]? = nil,
        label: String? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.placements = placements ?? Self.equalPlacements(columns: columns, rows: rows)
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        columns = try container.decode(Int.self, forKey: .columns)
        rows = try container.decode(Int.self, forKey: .rows)
        placements = try container.decodeIfPresent([TilePlacement].self, forKey: .placements)
            ?? Self.equalPlacements(columns: columns, rows: rows)
        label = try container.decodeIfPresent(String.self, forKey: .label)
    }

    var validOrFallback: TileLayoutConfig {
        guard columns > 0, rows > 0, !placements.isEmpty else { return .fallback }
        guard placements.allSatisfy({ placement in
            placement.x >= 0
                && placement.y >= 0
                && placement.width > 0
                && placement.height > 0
                && placement.maxX <= columns
                && placement.maxY <= rows
        }) else {
            return .fallback
        }
        guard hasCompleteCellCoverage else { return .fallback }
        return self
    }

    var tileCount: Int {
        placements.count
    }

    var singleLargeTileIndex: Int? {
        let indices = placements.indices.filter { placements[$0].spansMultipleCells }
        guard indices.count == 1 else { return nil }
        return indices[0]
    }

    var gridAspectRatio: CGSize {
        CGSize(width: columns * 16, height: rows * 9)
    }

    var initialWindowSize: CGSize {
        CGSize(width: columns * 640, height: rows * 360)
    }

    var minimumWindowSize: CGSize {
        CGSize(width: columns * 160, height: rows * 90)
    }

    var summary: String {
        if let label, !label.isEmpty {
            return label
        }
        if isUniformGrid {
            return "\(columns)x\(rows)"
        }
        return "\(columns)x\(rows)"
    }

    var nextLarger: TileLayoutConfig? {
        switch (columns, rows) {
        case (1, 1):
            return TileLayoutConfig(columns: 2, rows: 1)
        case (2, 1):
            return TileLayoutConfig(columns: 2, rows: 2)
        case (2, 2):
            return TileLayoutConfig(columns: 3, rows: 2)
        case (3, 2), (2, 3):
            return TileLayoutConfig(columns: 3, rows: 3)
        default:
            return nil
        }
    }

    var nextSmaller: TileLayoutConfig? {
        switch (columns, rows) {
        case (3, 3):
            return TileLayoutConfig(columns: 3, rows: 2)
        case (2, 3):
            return TileLayoutConfig(columns: 2, rows: 2)
        case (3, 2):
            return TileLayoutConfig(columns: 2, rows: 2)
        case (2, 2):
            return TileLayoutConfig(columns: 2, rows: 1)
        case (2, 1):
            return TileLayoutConfig(columns: 1, rows: 1)
        default:
            return nil
        }
    }

    static func automatic(tileCount: Int) -> TileLayoutConfig {
        guard tileCount > 0 else { return .fallback }
        let columns = Int(ceil(sqrt(Double(tileCount))))
        let rows = Int(ceil(Double(tileCount) / Double(columns)))
        return TileLayoutConfig(columns: columns, rows: rows)
    }

    func fitting(streamCount: Int) -> TileLayoutConfig {
        guard streamCount > tileCount else { return self }
        return .automatic(tileCount: streamCount)
    }

    func placement(at index: Int) -> TilePlacement? {
        guard placements.indices.contains(index) else { return nil }
        return placements[index]
    }

    func hasSameShape(as other: TileLayoutConfig) -> Bool {
        columns == other.columns
            && rows == other.rows
            && placements == other.placements
    }

    func canSwapTilesForDrag(sourceIndex: Int, targetIndex: Int) -> Bool {
        guard sourceIndex != targetIndex,
              placements.indices.contains(sourceIndex),
              placements.indices.contains(targetIndex)
        else {
            return false
        }
        return placements[sourceIndex].hasSameSize(as: placements[targetIndex])
    }

    private var isUniformGrid: Bool {
        placements == Self.equalPlacements(columns: columns, rows: rows)
    }

    private var hasCompleteCellCoverage: Bool {
        var occupied = Set<String>()
        for placement in placements {
            for y in placement.y..<placement.maxY {
                for x in placement.x..<placement.maxX {
                    let key = "\(x),\(y)"
                    guard !occupied.contains(key) else { return false }
                    occupied.insert(key)
                }
            }
        }
        return occupied.count == columns * rows
    }

    private static func equalPlacements(columns: Int, rows: Int) -> [TilePlacement] {
        guard columns > 0, rows > 0 else { return [] }
        return (0..<rows).flatMap { y in
            (0..<columns).map { x in
                TilePlacement(x: x, y: y, width: 1, height: 1)
            }
        }
    }

    private static func large(
        columns: Int,
        rows: Int,
        largeTiles: [TilePlacement],
        label: String
    ) -> TileLayoutConfig {
        var occupied = Set<String>()
        for tile in largeTiles {
            for y in tile.y..<tile.maxY {
                for x in tile.x..<tile.maxX {
                    occupied.insert("\(x),\(y)")
                }
            }
        }

        let smallTiles = equalPlacements(columns: columns, rows: rows).filter { placement in
            !occupied.contains("\(placement.x),\(placement.y)")
        }
        return TileLayoutConfig(
            columns: columns,
            rows: rows,
            placements: largeTiles + smallTiles,
            label: label
        )
    }
}

struct StreamConfig: Decodable, Identifiable {
    var id: String { title ?? url }
    var channelID: Int?
    var playbackMode: Int?
    var playbackModeName: String?
    var isUnconvertedPlayback: Bool?
    var title: String?
    var url: String
    var muted: Bool?
    var audioMode: AudioMode?
    var deinterlace: String?
    var mediaOptions: [String]?

    func hasSamePlaybackPipeline(as other: StreamConfig) -> Bool {
        url == other.url
            && deinterlace == other.deinterlace
            && mediaOptions == other.mediaOptions
    }
}
