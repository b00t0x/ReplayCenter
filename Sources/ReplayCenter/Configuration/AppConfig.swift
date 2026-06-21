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
            "vlcArguments=\(vlcArguments ?? [])",
            "mediaOptions=\(mediaOptions ?? [])"
        ].joined(separator: " ")
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
