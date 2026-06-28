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
    private(set) var broadcastClockState: BroadcastClockState?
    private(set) var currentAudioSelection: AudioSelection
    private(set) var isMuted: Bool
    private(set) var volumePercent: Int
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
        broadcastClockState = nil
        currentAudioSelection = AudioSelection(audioMode: stream?.audioMode ?? config.audioMode ?? .stereo)
        isMuted = stream?.muted ?? config.startMuted ?? true
        volumePercent = VolumeLevel.normalized(config.volumePercent)
        try? player.setAudioVolume(Volume(Float(volumePercent) / 100.0))
        player.isMuted = isMuted
        player.stereoMode = currentAudioSelection.filterAudioMode.stereoMode
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

    func updateStreamMetadata(_ stream: StreamConfig) {
        self.stream = stream
    }

    func clear() {
        stream = nil
        started = false
        playbackState = .idle
        audioStreamState = .unknown
        broadcastClockState = nil
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

    func setVolumePercent(_ percent: Int) {
        volumePercent = VolumeLevel.normalized(percent)
        do {
            try player.setAudioVolume(Volume(Float(volumePercent) / 100.0))
        } catch {
            log("volume failed percent=\(volumePercent) error=\(error)")
        }
    }

    func setAudioSelection(_ selection: AudioSelection) {
        guard audioStreamState.supportsAudioSelectionControls else { return }
        currentAudioSelection = selection
        let mode = selection.filterAudioMode
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
        broadcastClockState = nil
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
        currentAudioSelection = AudioSelection(audioMode: stream.audioMode ?? config.audioMode ?? .stereo)
        player.stereoMode = currentAudioSelection.filterAudioMode.stereoMode
        playbackState = .starting
        audioStreamState = .unknown
        broadcastClockState = nil
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
            let media = try pipeline.start(initialMode: currentAudioSelection.filterAudioMode)
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

            setVolumePercent(volumePercent)
            applyDeinterlaceIfNeeded()
            try player.play(media)
            playbackState = .playing
            log("play url=\(stream.url) deinterlace=\(effectiveDeinterlaceLabel) volume=\(volumePercent) audioSelection=\(currentAudioSelection.rawValue) filter=\((config.dualMonoFilter ?? .default).summary)")
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
            if state.supportsAudioSelectionControls {
                dualMonoFilterPipeline?.setAudioMode(currentAudioSelection.filterAudioMode)
            }
        case let .broadcastClockChanged(state):
            broadcastClockState = state
        case let .streamInputEnded(error):
            if let error {
                failPlayback("stream input ended: \(error)")
            } else {
                failPlayback("stream input ended")
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

    func streamInfoText(displayPixelSize: CGSize?) -> String {
        guard let stream else { return "未割り当て" }
        let modeText: String
        if let playbackMode = stream.playbackMode {
            let modeName = stream.playbackModeName ?? "mode \(playbackMode)"
            modeText = "\(modeName) / mode \(playbackMode)"
        } else {
            modeText = "固定URL"
        }

        let sourceText: String
        if let isUnconverted = stream.isUnconvertedPlayback {
            sourceText = isUnconverted ? "raw" : "transcoded"
        } else {
            sourceText = "source=?"
        }

        var lines = [
            modeText,
            "\(sourceText) / deinterlace=\(effectiveDeinterlaceLabel)",
            "audio=\(audioStreamState.displayText) / \(currentAudioSelection.displayText)"
        ]
        if let displayPixelSize {
            lines.append("input=\(formatOptionalSize(player.videoSize)) / tile=\(formatDisplaySize(displayPixelSize))")
        }
        lines.append(inputClockDebugText)
        return lines.joined(separator: "\n")
    }

    private func formatOptionalSize(_ size: CGSize?) -> String {
        guard let size else { return "?" }
        return formatDisplaySize(size)
    }

    private func formatDisplaySize(_ size: CGSize) -> String {
        let width = max(Int(size.width.rounded()), 0)
        let height = max(Int(size.height.rounded()), 0)
        return "\(width)x\(height)"
    }

    private var inputClockDebugText: String {
        guard let broadcastClockState else {
            return "inputClock=時刻未取得"
        }
        let offsetSeconds = broadcastClockState.delaySeconds
        let tableSuffix = broadcastClockState.table.map { " \($0)" } ?? ""
        if offsetSeconds.isFinite {
            return "inputClock=\(formatDelay(offsetSeconds))\(tableSuffix)"
        }
        return "inputClock=?\(tableSuffix)"
    }

    private func formatDelay(_ seconds: TimeInterval) -> String {
        let rounded = Int(seconds.rounded())
        let sign = rounded < 0 ? "-" : ""
        let absolute = abs(rounded)
        if absolute < 60 {
            return "\(sign)\(absolute)s"
        }
        let minutes = absolute / 60
        let remainingSeconds = absolute % 60
        return "\(sign)\(minutes)m\(String(format: "%02d", remainingSeconds))s"
    }

    private func log(_ message: String) {
        let label = stream.map { $0.title ?? $0.url } ?? "empty tile"
        fputs("[\(label)] \(message)\n", stderr)
    }
}
