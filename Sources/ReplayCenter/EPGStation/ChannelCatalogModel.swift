import Foundation
import Observation

struct ChannelSelectionItem: Identifiable, Hashable {
    var id: Int { channel.id }
    let channel: EPGStationChannel
    let displayName: String
    let category: BroadcastChannelCategory
    let currentProgram: ScheduleProgram?
}

enum BroadcastChannelCategory: String, CaseIterable, Identifiable, Hashable {
    case terrestrial
    case bs
    case cs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .terrestrial:
            return "地上波"
        case .bs:
            return "BS"
        case .cs:
            return "CS"
        }
    }
}

@MainActor
@Observable
final class ChannelCatalogModel {
    private let client: EPGStationClient
    private var hasLoaded = false

    var items: [ChannelSelectionItem] = []
    var playbackModeOptionsByContainer: [LiveStreamContainer: [EPGStationLiveStreamModeOption]] = [:]
    var isLoading = false
    var errorMessage: String?
    var configErrorMessage: String?

    init(client: EPGStationClient) {
        self.client = client
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        isLoading = true
        errorMessage = nil
        configErrorMessage = nil
        defer {
            isLoading = false
            hasLoaded = true
        }

        do {
            let channels = try await client.fetchChannels()
            let schedules = try await client.fetchBroadcastingSchedules()
            var programsByChannelID: [Int: ScheduleProgram] = [:]
            for schedule in schedules {
                if let currentProgram = schedule.currentProgram {
                    programsByChannelID[schedule.channel.id] = currentProgram
                }
            }

            items = Self.selectionItems(
                from: channels,
                programsByChannelID: programsByChannelID
            )
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        do {
            let config = try await client.fetchConfig()
            playbackModeOptionsByContainer = [
                .m2ts: config.liveStreamModeOptions(for: .m2ts),
                .m2tsll: config.liveStreamModeOptions(for: .m2tsll)
            ]
        } catch {
            playbackModeOptionsByContainer = [:]
            configErrorMessage = error.localizedDescription
        }
    }

    func playbackModeOptions(for container: LiveStreamContainer) -> [EPGStationLiveStreamModeOption] {
        playbackModeOptionsByContainer[container] ?? []
    }

    private static func selectionItems(
        from channels: [EPGStationChannel],
        programsByChannelID: [Int: ScheduleProgram]
    ) -> [ChannelSelectionItem] {
        let visibleChannels = channels.compactMap { channel -> (EPGStationChannel, BroadcastChannelCategory)? in
            guard let category = category(for: channel) else { return nil }
            return (channel, category)
        }
        var seenNameCounts: [String: Int] = [:]
        return visibleChannels.map { channel, category in
            let baseName = baseDisplayName(for: channel)
            let seenCount = seenNameCounts[baseName, default: 0]
            seenNameCounts[baseName] = seenCount + 1
            let displayName = seenCount == 0
                ? baseName
                : "\(baseName) (\(channel.serviceId))"
            return ChannelSelectionItem(
                channel: channel,
                displayName: displayName,
                category: category,
                currentProgram: programsByChannelID[channel.id]
            )
        }
    }

    private static func category(for channel: EPGStationChannel) -> BroadcastChannelCategory? {
        switch channel.networkId {
        case 11:
            return nil
        case 4:
            return .bs
        case 6, 7:
            return .cs
        default:
            return .terrestrial
        }
    }

    private static func baseDisplayName(for channel: EPGStationChannel) -> String {
        let halfWidthName = channel.halfWidthName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !halfWidthName.isEmpty {
            return halfWidthName
        }
        return String(channel.id)
    }
}
