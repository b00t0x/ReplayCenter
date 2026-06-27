import Foundation
import Observation
import SwiftVLC

@MainActor
@Observable
final class TileModel: Identifiable {
    let id = UUID()
    private(set) var stream: StreamConfig?
    private(set) var playbackState: TilePlaybackState
    private(set) var audioStreamState: AudioStreamState
    private(set) var currentAudioMode: AudioMode
    private(set) var isMuted: Bool
    let player: Player
    private let config: AppConfig
    private var started = false
    private var dualMonoFilterPipeline: DualMonoFilterPipeline?
    private var activePipelineID: UUID?

    init(stream: StreamConfig?, config: AppConfig, instance: VLCInstance) {
        self.stream = stream
        self.config = config
        self.player = Player(instance: instance)
        playbackState = .idle
        audioStreamState = .unknown
        currentAudioMode = stream?.audioMode ?? config.audioMode ?? .stereo
        isMuted = stream?.muted ?? config.startMuted ?? true
        player.isMuted = isMuted
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
        playbackState = .idle
        audioStreamState = .unknown
        activePipelineID = nil
        player.stop()
        dualMonoFilterPipeline?.stop()
        dualMonoFilterPipeline = nil
        setMuted(true)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        player.isMuted = muted
    }

    func setAudioMode(_ mode: AudioMode) {
        guard audioStreamState.supportsCurrentAudioModeControls else { return }
        currentAudioMode = mode
        player.stereoMode = mode.stereoMode
        dualMonoFilterPipeline?.setAudioMode(mode)
    }

    func reload() {
        guard stream != nil else { return }
        started = true
        start()
    }

    func shutdown() async {
        playbackState = .idle
        audioStreamState = .unknown
        activePipelineID = nil
        player.stop()
        dualMonoFilterPipeline?.stop()
        dualMonoFilterPipeline = nil
        await player.shutdown()
    }

    private func start() {
        guard let stream else { return }
        guard let url = URL(string: stream.url) else {
            playbackState = .failed("invalid url")
            log("invalid url=\(stream.url)")
            return
        }
        currentAudioMode = stream.audioMode ?? config.audioMode ?? .stereo
        player.stereoMode = currentAudioMode.stereoMode
        playbackState = .starting
        audioStreamState = .unknown
        activePipelineID = nil
        player.stop()
        dualMonoFilterPipeline?.stop()
        dualMonoFilterPipeline = nil

        do {
            let pipelineID = UUID()
            let pipeline = DualMonoFilterPipeline(
                streamURL: url.absoluteString,
                label: stream.title ?? stream.url,
                config: config.dualMonoFilter ?? .default
            ) { [weak self] event in
                Task { @MainActor in
                    self?.handlePipelineEvent(event, pipelineID: pipelineID)
                }
            }
            activePipelineID = pipelineID
            dualMonoFilterPipeline = pipeline
            let media = try pipeline.start(initialMode: currentAudioMode)
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
            playbackState = .playing
            log("play url=\(stream.url) deinterlace=\(effectiveDeinterlaceLabel) audioMode=\(currentAudioMode.rawValue) filter=\((config.dualMonoFilter ?? .default).summary)")
        } catch {
            playbackState = .failed(error.localizedDescription)
            activePipelineID = nil
            dualMonoFilterPipeline?.stop()
            dualMonoFilterPipeline = nil
            log("play failed error=\(error)")
        }
    }

    private func handlePipelineEvent(_ event: DualMonoFilterPipelineEvent, pipelineID: UUID) {
        guard activePipelineID == pipelineID else { return }

        switch event {
        case let .audioStateChanged(state):
            guard audioStreamState != state else { return }
            audioStreamState = state
            log("audio state changed state=\(state.rawValue)")
        case let .curlExited(status, reason, stderr):
            let detail = "curl exited status=\(status) reason=\(reason)"
            if let stderr {
                failPlayback("\(detail): \(stderr)")
            } else {
                failPlayback(detail)
            }
        case let .filterExited(status, reason):
            failPlayback("dual mono filter exited status=\(status) reason=\(reason)")
        }
    }

    private func failPlayback(_ message: String) {
        playbackState = .failed(message)
        activePipelineID = nil
        player.stop()
        dualMonoFilterPipeline?.stop()
        dualMonoFilterPipeline = nil
        log("playback failed \(message)")
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
