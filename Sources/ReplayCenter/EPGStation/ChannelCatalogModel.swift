import Foundation
import Observation

struct ChannelSelectionItem: Identifiable, Hashable {
    var id: Int { channel.id }
    let channel: EPGStationChannel
    let currentProgram: ScheduleProgram?
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

            items = channels.map { channel in
                ChannelSelectionItem(channel: channel, currentProgram: programsByChannelID[channel.id])
            }
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
}
