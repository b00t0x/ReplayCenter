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
}

enum LiveStreamContainer: String, Codable, Hashable {
    case m2ts
    case m2tsll
}
