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
            "audioOnlyFocusedTile=\(audioOnlyFocusedTile.map(String.init) ?? "<nil>")",
            "startMuted=\(startMuted.map(String.init) ?? "<nil>")",
            "audioMode=\(audioMode?.rawValue ?? "<nil>")",
            "tileLayout=\(tileLayout?.summary ?? "<auto>")",
            "startupStreams=\(startupStreams?.rawValue ?? "<nil>")",
            "vlcArguments=\(vlcArguments ?? [])",
            "mediaOptions=\(mediaOptions ?? [])"
        ].joined(separator: " ")
    }
}

enum StartupStreamsMode: String, Codable, Hashable {
    case configured
    case empty
}

struct TileLayoutConfig: Codable, Equatable {
    let columns: Int
    let rows: Int

    static let fallback = TileLayoutConfig(columns: 1, rows: 1)

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
