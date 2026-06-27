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
            "dualMonoFilter=\((dualMonoFilter ?? .default).summary)",
            "vlcArguments=\(vlcArguments ?? [])",
            "mediaOptions=\(mediaOptions ?? [])"
        ].joined(separator: " ")
    }
}

struct AppSettings: Codable, Equatable {
    var startupStreams: StartupStreamsMode?
    var volumePercent: Int?

    static let empty = AppSettings(startupStreams: nil, volumePercent: nil)

    static func defaults(from config: AppConfig) -> AppSettings {
        AppSettings(
            startupStreams: config.startupStreams ?? .configured,
            volumePercent: VolumeLevel.normalized(config.volumePercent)
        )
    }

    func fillingDefaults(from config: AppConfig) -> AppSettings {
        AppSettings(
            startupStreams: startupStreams ?? config.startupStreams ?? .configured,
            volumePercent: VolumeLevel.normalized(volumePercent ?? config.volumePercent)
        )
    }

    var summary: String {
        [
            "startupStreams=\(startupStreams?.rawValue ?? "<nil>")",
            "volumePercent=\(volumePercent.map(String.init) ?? "<nil>")"
        ].joined(separator: " ")
    }
}

extension AppConfig {
    func applying(_ settings: AppSettings?) -> AppConfig {
        guard let settings else { return self }
        var config = self
        if let startupStreams = settings.startupStreams {
            config.startupStreams = startupStreams
        }
        if let volumePercent = settings.volumePercent {
            config.volumePercent = VolumeLevel.normalized(volumePercent)
        }
        return config
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
    var curlPath: String?
    var muxSelectedToStereo: Bool?

    static let `default` = DualMonoFilterConfig(
        filterPath: nil,
        curlPath: nil,
        muxSelectedToStereo: false
    )

    var effectiveMuxSelectedToStereo: Bool {
        muxSelectedToStereo ?? false
    }

    var summary: String {
        [
            "filterPath=\(filterPath ?? "<auto>")",
            "curlPath=\(curlPath ?? "/usr/bin/curl")",
            "muxSelectedToStereo=\(effectiveMuxSelectedToStereo)"
        ].joined(separator: ",")
    }
}

enum StartupStreamsMode: String, Codable, Hashable {
    case configured
    case empty
}

struct TileLayoutConfig: Codable, Equatable, Hashable {
    let columns: Int
    let rows: Int

    static let fallback = TileLayoutConfig(columns: 1, rows: 1)
    static let presets = [
        TileLayoutConfig(columns: 1, rows: 1),
        TileLayoutConfig(columns: 2, rows: 1),
        TileLayoutConfig(columns: 2, rows: 2),
        TileLayoutConfig(columns: 3, rows: 2),
        TileLayoutConfig(columns: 2, rows: 3),
        TileLayoutConfig(columns: 3, rows: 3)
    ]

    var validOrFallback: TileLayoutConfig {
        guard columns > 0, rows > 0 else { return .fallback }
        return self
    }

    var tileCount: Int {
        columns * rows
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
        "\(columns)x\(rows)"
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
}

struct StreamConfig: Decodable, Identifiable {
    var id: String { title ?? url }
    var title: String?
    var url: String
    var muted: Bool?
    var audioMode: AudioMode?
    var deinterlace: String?
    var mediaOptions: [String]?
}
