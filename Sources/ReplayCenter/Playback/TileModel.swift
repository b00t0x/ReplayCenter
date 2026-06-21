import Foundation
import Observation
import SwiftVLC

@MainActor
@Observable
final class TileModel: Identifiable {
    let id = UUID()
    private(set) var stream: StreamConfig?
    let player: Player
    private let config: AppConfig
    private var started = false
    private var currentAudioMode: AudioMode

    init(stream: StreamConfig?, config: AppConfig, instance: VLCInstance) {
        self.stream = stream
        self.config = config
        self.player = Player(instance: instance)
        currentAudioMode = stream?.audioMode ?? config.audioMode ?? .stereo
        player.isMuted = stream?.muted ?? config.startMuted ?? true
        player.stereoMode = currentAudioMode.stereoMode
    }

    func startIfNeeded() {
        guard !started else { return }
        guard stream != nil else { return }
        started = true
        start()
    }

    func play(stream: StreamConfig) {
        self.stream = stream
        started = true
        start()
    }

    func clear() {
        stream = nil
        started = false
        player.stop()
        player.isMuted = true
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func setAudioMode(_ mode: AudioMode) {
        currentAudioMode = mode
        player.stereoMode = mode.stereoMode
    }

    func shutdown() async {
        await player.shutdown()
    }

    private func start() {
        guard let stream else { return }
        guard let url = URL(string: stream.url) else {
            log("invalid url=\(stream.url)")
            return
        }

        do {
            let media = try Media(url: url)
            if let networkCachingMs = config.networkCachingMs {
                media.addOption(":network-caching=\(networkCachingMs)")
                media.addOption(":live-caching=\(networkCachingMs)")
            }
            for option in config.mediaOptions ?? [] {
                media.addOption(option)
            }
            for option in stream.mediaOptions ?? [] {
                media.addOption(option)
            }

            applyDeinterlaceIfNeeded()
            try player.play(media)
            log("play url=\(stream.url) deinterlace=\(effectiveDeinterlaceLabel)")
        } catch {
            log("play failed error=\(error)")
        }
    }

    private func applyDeinterlaceIfNeeded() {
        let deinterlace = effectiveDeinterlaceLabel
        guard deinterlace != "<unchanged>" else { return }

        do {
            switch deinterlace.lowercased() {
            case "off", "none", "false", "disabled", "disable":
                try player.setDeinterlace(state: 0)
            case "auto":
                try player.setDeinterlace(state: -1)
            default:
                try player.setDeinterlace(state: 1, mode: deinterlace)
            }
        } catch {
            log("deinterlace failed mode=\(deinterlace) error=\(error)")
        }
    }

    private var effectiveDeinterlaceLabel: String {
        guard let stream else { return config.effectiveDeinterlaceLabel }
        let streamValue = stream.deinterlace?.trimmingCharacters(in: .whitespacesAndNewlines)
        if streamValue?.isEmpty == false {
            return streamValue!
        }
        return config.effectiveDeinterlaceLabel
    }

    private func log(_ message: String) {
        let label = stream.map { $0.title ?? $0.url } ?? "empty tile"
        fputs("[\(label)] \(message)\n", stderr)
    }
}
