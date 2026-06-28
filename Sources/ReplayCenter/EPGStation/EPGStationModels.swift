import Foundation

struct EPGStationChannel: Decodable, Identifiable, Hashable {
    let id: Int
    let serviceId: Int
    let networkId: Int
    let name: String
    let halfWidthName: String?
    let remoteControlKeyId: Int?
    let hasLogoData: Bool
    let channelType: ChannelType
    let channel: String?
    let type: Int?
}

enum ChannelType: String, Decodable, Hashable {
    case gr = "GR"
    case bs = "BS"
    case cs = "CS"
    case sky = "SKY"
}

struct BroadcastingSchedule: Decodable, Identifiable, Hashable {
    var id: Int { channel.id }
    let channel: ScheduleChannel
    let programs: [ScheduleProgram]

    var currentProgram: ScheduleProgram? {
        let now = Date()
        return programs.first { $0.startAt <= now && now < $0.endAt }
    }
}

struct ScheduleChannel: Decodable, Identifiable, Hashable {
    let id: Int
    let serviceId: Int
    let networkId: Int
    let name: String
    let remoteControlKeyId: Int?
    let hasLogoData: Bool
    let channelType: ChannelType
    let type: Int?
}

struct ScheduleProgram: Decodable, Identifiable, Hashable {
    let id: Int
    let channelId: Int
    let startAt: Date
    let endAt: Date
    let isFree: Bool
    let name: String
    let description: String?
    let extended: String?
    let genre1: Int?
    let subGenre1: Int?
    let genre2: Int?
    let subGenre2: Int?
    let genre3: Int?
    let subGenre3: Int?
    let videoType: String?
    let videoResolution: String?
    let audioSamplingRate: Int?
    let audioComponentType: Int?

    func hasGenre(_ code: ProgramGenreCode) -> Bool {
        genrePairs.contains { genre, subGenre in
            code.matches(genre: genre, subGenre: subGenre)
        }
    }

    var genrePairs: [(genre: Int?, subGenre: Int?)] {
        [
            (genre1, subGenre1),
            (genre2, subGenre2),
            (genre3, subGenre3)
        ]
    }
}

enum LiveStreamContainer: String, Codable, Hashable {
    case m2ts
    case m2tsll
}

struct EPGStationConfig: Decodable, Hashable {
    let streamConfig: EPGStationStreamConfig?

    func liveStreamModeOptions(for container: LiveStreamContainer) -> [EPGStationLiveStreamModeOption] {
        let items: [EPGStationM2TSStreamParam]
        switch container {
        case .m2ts:
            items = streamConfig?.live?.ts?.m2ts ?? []
        case .m2tsll:
            items = streamConfig?.live?.ts?.m2tsll ?? []
        }
        return items.enumerated().map { index, item in
            EPGStationLiveStreamModeOption(
                mode: index,
                name: item.name,
                isUnconverted: item.isUnconverted
            )
        }
    }
}

struct EPGStationStreamConfig: Decodable, Hashable {
    let live: EPGStationLiveStreamConfig?
}

struct EPGStationLiveStreamConfig: Decodable, Hashable {
    let ts: EPGStationLiveTSStreamConfig?
}

struct EPGStationLiveTSStreamConfig: Decodable, Hashable {
    let m2ts: [EPGStationM2TSStreamParam]?
    let m2tsll: [EPGStationM2TSStreamParam]?
}

struct EPGStationM2TSStreamParam: Decodable, Hashable {
    let name: String
    let isUnconverted: Bool?

    private enum CodingKeys: String, CodingKey {
        case name
        case isUnconverted
    }

    init(from decoder: Decoder) throws {
        if let name = try? decoder.singleValueContainer().decode(String.self) {
            self.name = name
            self.isUnconverted = nil
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        isUnconverted = try container.decodeIfPresent(Bool.self, forKey: .isUnconverted)
    }
}

struct EPGStationLiveStreamModeOption: Identifiable, Hashable {
    let mode: Int
    let name: String
    let isUnconverted: Bool?

    var id: Int { mode }

    var label: String {
        "\(name) (mode \(mode))"
    }

    static func fallback(mode: Int) -> EPGStationLiveStreamModeOption {
        EPGStationLiveStreamModeOption(
            mode: mode,
            name: "mode \(mode)",
            isUnconverted: false
        )
    }
}
