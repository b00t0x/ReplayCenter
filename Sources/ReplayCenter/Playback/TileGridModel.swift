import Foundation
import Observation
import SwiftVLC

@MainActor
@Observable
final class TileGridModel {
    private struct ArmedEventRelay {
        let candidate: EventRelayCandidate
        let generation: UUID
        var task: Task<Void, Never>?
    }

    private struct InferredEventRelaySource: Equatable {
        let programID: Int
        let channelID: Int
        let name: String
        let endAt: Date
    }

    private struct InferredEventRelayTarget: Equatable {
        let channelID: Int
        let displayName: String
    }

    private struct ArmedInferredEventRelay {
        let source: InferredEventRelaySource
        let generation: UUID
        var target: InferredEventRelayTarget?
        var task: Task<Void, Never>?
    }

    private enum InferredEventRelayResolution {
        case target(InferredEventRelayTarget)
        case unavailable(String)
    }

    private static let inferredRelayLookahead: TimeInterval = 3 * 60
    private static let inferredRelayRetryInterval: TimeInterval = 30
    private static let inferredRelayFinalCheckLead: TimeInterval = 5

    var focusedIndex = 0
    var tiles: [TileModel]
    var layout: TileLayoutConfig
    var settings: AppSettings
    var channelSettings: ChannelSettings
    var playbackModeOptions: [EPGStationLiveStreamModeOption]
    var channelCatalog: ChannelCatalogModel?
    var defaultVolumePercent: Int
    var isSettingsPresented = false
    var isEPGStationSetupRequired = false
    @ObservationIgnored var onLayoutChanged: ((_ oldLayout: TileLayoutConfig, _ newLayout: TileLayoutConfig) -> Void)?
    @ObservationIgnored var onSettingsChanged: ((AppSettings) -> Void)?
    @ObservationIgnored var onSettingsPresentationChanged: ((Bool) -> Void)?
    @ObservationIgnored var onFocusedTitleChanged: ((String) -> Void)?
    @ObservationIgnored var onFocusedChannelSelectionRequested: (() -> Void)?
    @ObservationIgnored var onTileLayoutPickerRequested: (() -> Void)?
    private var hasAppliedFocus = false
    private var config: AppConfig
    private let instance: VLCInstance
    private var epgStationClient: EPGStationClient?
    @ObservationIgnored private var armedEventRelays: [UUID: ArmedEventRelay] = [:]
    @ObservationIgnored private var armedInferredEventRelays: [UUID: ArmedInferredEventRelay] = [:]

    init(config: AppConfig, instance: VLCInstance, restoredState: AppState? = nil) {
        self.config = config
        self.instance = instance
        let initialSettings = (restoredState?.settings ?? .empty).fillingDefaults(from: config)
        self.settings = initialSettings
        self.channelSettings = (restoredState?.channelSettings ?? .empty).normalized
        self.playbackModeOptions = [
            EPGStationLiveStreamModeOption.fallback(mode: initialSettings.largeTilePlayback?.liveStreamMode ?? 0)
        ]
        let initialVolumePercent = VolumeLevel.normalized(initialSettings.volumePercent)
        self.defaultVolumePercent = initialVolumePercent
        var config = config
        config.volumePercent = initialVolumePercent
        self.config = config
        let initialStreams = config.streams
        let initialLayout = (restoredState?.tileLayout ?? config.tileLayout ?? .automatic(tileCount: max(initialStreams.count, 1)))
            .validOrFallback
            .fitting(streamCount: initialStreams.count)
        self.layout = initialLayout
        self.tiles = (0..<initialLayout.tileCount).map { index in
            TileModel(
                stream: initialStreams.indices.contains(index) ? initialStreams[index] : nil,
                config: config,
                instance: instance
            )
        }
        if let epgStationBaseURL = config.epgStationBaseURL {
            let client = EPGStationClient(baseURL: epgStationBaseURL)
            self.epgStationClient = client
            self.channelCatalog = ChannelCatalogModel(client: client)
        } else {
            self.epgStationClient = nil
            self.channelCatalog = nil
        }
        for tile in tiles {
            bindEventRelayCallbacks(to: tile)
        }
    }

    func focusInitialTileIfNeeded() {
        guard !tiles.isEmpty else { return }
        focus(0)
    }

    var focusedWindowTitle: String {
        guard tiles.indices.contains(focusedIndex),
              let stream = tiles[focusedIndex].stream
        else {
            return "ReplayCenter"
        }

        if let overlayInfo = channelProgramOverlayInfo(for: tiles[focusedIndex]) {
            return overlayInfo.singleLineText
        }
        return stream.title ?? stream.url
    }

    var focusedTileHasStream: Bool {
        guard tiles.indices.contains(focusedIndex) else { return false }
        return tiles[focusedIndex].stream != nil
    }

    var focusedTileVolumePercent: Int {
        guard tiles.indices.contains(focusedIndex) else { return VolumeLevel.maximum }
        return tiles[focusedIndex].volumePercent
    }

    var focusedTileIsMuted: Bool {
        guard tiles.indices.contains(focusedIndex) else { return false }
        return tiles[focusedIndex].isMuted
    }

    var focusedTileAudioSelection: AudioSelection {
        guard tiles.indices.contains(focusedIndex) else { return .primary }
        return tiles[focusedIndex].currentAudioSelection
    }

    var focusedTileSupportsAudioSelection: Bool {
        guard tiles.indices.contains(focusedIndex) else { return false }
        return tiles[focusedIndex].audioStreamState.supportsAudioSelectionControls
    }

    func refreshFocusedWindowTitle() {
        notifyFocusedTitleChanged()
    }

    func focus(_ index: Int, forceAudioUpdate: Bool = false) {
        guard tiles.indices.contains(index) else { return }
        let targetIndex = promotedFocusIndex(for: index)
        applyFocus(targetIndex, forceAudioUpdate: forceAudioUpdate)
    }

    @discardableResult
    func swapTilesForDrag(sourceIndex: Int, targetIndex: Int) -> Bool {
        guard layout.canSwapTilesForDrag(sourceIndex: sourceIndex, targetIndex: targetIndex) else {
            return false
        }
        tiles.swapAt(sourceIndex, targetIndex)
        applyPlaybackProfilesToTiles(at: [sourceIndex, targetIndex], restartPolicy: .whenModeChanges)
        applyFocus(focusedIndex, forceAudioUpdate: true)
        return true
    }

    func canSwapTilesForDrag(sourceIndex: Int, targetIndex: Int?) -> Bool {
        guard let targetIndex else { return false }
        return layout.canSwapTilesForDrag(sourceIndex: sourceIndex, targetIndex: targetIndex)
    }

    private func applyFocus(_ index: Int, forceAudioUpdate: Bool = false) {
        guard tiles.indices.contains(index) else { return }
        let shouldUpdateAudio = forceAudioUpdate || !hasAppliedFocus || focusedIndex != index
        focusedIndex = index
        hasAppliedFocus = true
        notifyFocusedTitleChanged()

        guard shouldUpdateAudio else { return }
        for (tileIndex, tile) in tiles.enumerated() {
            tile.setMuted(tileIndex != index)
        }
    }

    private func promotedFocusIndex(for index: Int) -> Int {
        guard settings.keepFocusOnSingleLargeTile ?? true,
              let largeIndex = layout.singleLargeTileIndex,
              largeIndex != index,
              tiles.indices.contains(largeIndex)
        else {
            return index
        }
        if swapTiles(index, largeIndex, focusedIndexAfterSwap: nil) {
            applyPlaybackProfilesToTiles(at: [index, largeIndex], restartPolicy: .whenModeChanges)
            return largeIndex
        }
        return index
    }

    @discardableResult
    private func swapTiles(
        _ sourceIndex: Int,
        _ targetIndex: Int,
        focusedIndexAfterSwap: Int?
    ) -> Bool {
        guard sourceIndex != targetIndex,
              tiles.indices.contains(sourceIndex),
              tiles.indices.contains(targetIndex)
        else {
            return false
        }

        tiles.swapAt(sourceIndex, targetIndex)
        if let focusedIndexAfterSwap {
            applyFocus(focusedIndexAfterSwap)
        } else if focusedIndex == sourceIndex {
            focusedIndex = targetIndex
        } else if focusedIndex == targetIndex {
            focusedIndex = sourceIndex
        }
        return true
    }

    func setFocusedAudioSelection(_ selection: AudioSelection) {
        guard tiles.indices.contains(focusedIndex) else { return }
        guard tiles[focusedIndex].stream != nil else { return }
        tiles[focusedIndex].setAudioSelection(selection)
    }

    func toggleFocusedTileMuted() {
        guard tiles.indices.contains(focusedIndex) else { return }
        let tile = tiles[focusedIndex]
        guard tile.stream != nil else { return }
        tile.setMuted(!tile.isMuted)
    }

    func increaseVolume(stoppingAtRepeatBoundary: Bool = false) {
        changeFocusedTileVolume(by: VolumeLevel.step, stoppingAtRepeatBoundary: stoppingAtRepeatBoundary)
    }

    func decreaseVolume(stoppingAtRepeatBoundary: Bool = false) {
        changeFocusedTileVolume(by: -VolumeLevel.step, stoppingAtRepeatBoundary: stoppingAtRepeatBoundary)
    }

    private func changeFocusedTileVolume(by offset: Int, stoppingAtRepeatBoundary: Bool = false) {
        guard tiles.indices.contains(focusedIndex) else { return }
        let tile = tiles[focusedIndex]
        guard tile.stream != nil else { return }
        tile.setVolumePercent(
            VolumeLevel.changed(
                from: tile.volumePercent,
                by: offset,
                stoppingAtRepeatBoundary: stoppingAtRepeatBoundary
            )
        )
    }

    func playFocusedChannel(_ channel: EPGStationChannel) {
        playChannel(channel, at: focusedIndex, focusAfterPlay: true)
    }

    func requestFocusedChannelSelection() {
        onFocusedChannelSelectionRequested?()
    }

    func requestTileLayoutPicker() {
        onTileLayoutPickerRequested?()
    }

    func playChannel(_ item: ChannelSelectionItem, at index: Int, focusAfterPlay: Bool = false) {
        playChannel(
            item.channel,
            title: item.displayName,
            at: index,
            focusAfterPlay: focusAfterPlay
        )
    }

    func playChannel(_ channel: EPGStationChannel, at index: Int, focusAfterPlay: Bool = false) {
        playChannel(channel, title: channel.name, at: index, focusAfterPlay: focusAfterPlay)
    }

    private func playChannel(
        _ channel: EPGStationChannel,
        title: String,
        at index: Int,
        focusAfterPlay: Bool = false
    ) {
        guard tiles.indices.contains(index), let epgStationClient else { return }

        let stream = streamConfig(
            channelID: channel.id,
            title: title,
            tileIndex: index,
            epgStationClient: epgStationClient
        )
        disarmInferredEventRelay(for: tiles[index].id)
        tiles[index].setEventRelayFollowStatus(nil)
        tiles[index].play(
            stream: stream,
            initialVolumePercent: VolumeLevel.normalized(settings.volumePercent ?? defaultVolumePercent)
        )
        if focusAfterPlay {
            focus(index, forceAudioUpdate: true)
        } else if index == focusedIndex {
            notifyFocusedTitleChanged()
        }
    }

    private func streamConfig(
        channelID: Int,
        title: String?,
        tileIndex: Int,
        epgStationClient: EPGStationClient
    ) -> StreamConfig {
        let profile = playbackProfile(for: tileIndex)
        let modeOption = playbackModeOption(for: profile.liveStreamMode)
        let url = epgStationClient.liveStreamURL(
            channelID: channelID,
            container: liveStreamContainer,
            mode: profile.liveStreamMode
        )
        return StreamConfig(
            channelID: channelID,
            playbackMode: profile.liveStreamMode,
            playbackModeName: modeOption?.name,
            isUnconvertedPlayback: modeOption?.isUnconverted,
            title: title,
            url: url.absoluteString,
            audioMode: nil,
            deinterlace: profile.deinterlaceForPlayback(isUnconverted: modeOption?.isUnconverted),
            mediaOptions: nil
        )
    }

    private func playbackProfile(for tileIndex: Int) -> TilePlaybackProfile {
        let isLargeTile = layout.tileCount == 1
            || layout.placement(at: tileIndex)?.spansMultipleCells == true
        let fallback = TilePlaybackProfile.fallback
        if isLargeTile {
            return settings.largeTilePlayback ?? config.largeTilePlayback ?? fallback
        }
        return settings.smallTilePlayback ?? config.smallTilePlayback ?? fallback
    }

    var liveStreamContainer: LiveStreamContainer {
        config.liveStreamContainer ?? .m2ts
    }

    func setPlaybackModeOptions(_ options: [EPGStationLiveStreamModeOption]) {
        let normalizedOptions = options.isEmpty
            ? [.fallback(mode: TilePlaybackProfile.fallback.liveStreamMode)]
            : options
        guard playbackModeOptions != normalizedOptions else { return }
        playbackModeOptions = normalizedOptions
        updatePlaybackMetadataForTiles()
    }

    func playbackModeOptions(including currentMode: Int) -> [EPGStationLiveStreamModeOption] {
        var options = playbackModeOptions
        if !options.contains(where: { $0.mode == currentMode }) {
            options.append(.fallback(mode: currentMode))
        }
        return options.sorted { $0.mode < $1.mode }
    }

    private func playbackModeOption(for mode: Int) -> EPGStationLiveStreamModeOption? {
        playbackModeOptions.first { $0.mode == mode }
    }

    func clearFocusedTile() {
        clearTile(at: focusedIndex)
    }

    func clearTile(at index: Int) {
        guard tiles.indices.contains(index) else { return }
        disarmInferredEventRelay(for: tiles[index].id)
        tiles[index].clear()
        if index == focusedIndex {
            focus(index, forceAudioUpdate: true)
        } else {
            applyFocus(focusedIndex)
        }
    }

    func reloadFocusedTile() {
        guard tiles.indices.contains(focusedIndex) else { return }
        disarmInferredEventRelay(for: tiles[focusedIndex].id)
        tiles[focusedIndex].reload()
        focus(focusedIndex)
    }

    func presentSettings(requiresEPGStationConnection: Bool = false) {
        if requiresEPGStationConnection {
            isEPGStationSetupRequired = true
        }
        guard !isSettingsPresented else { return }
        isSettingsPresented = true
        onSettingsPresentationChanged?(true)
    }

    func dismissSettings() {
        guard isSettingsPresented else { return }
        guard !isEPGStationSetupRequired else { return }
        isSettingsPresented = false
        onSettingsPresentationChanged?(false)
    }

    func completeEPGStationSetup() {
        isEPGStationSetupRequired = false
        dismissSettings()
    }

    func increaseTileCapacity() {
        guard let nextLayout = layout.nextLarger else { return }
        applyTileLayout(nextLayout, focusFirstNewTile: true)
    }

    func decreaseTileCapacity() {
        guard let nextLayout = layout.nextSmaller else { return }
        applyTileLayout(nextLayout)
    }

    func setShowStreamInfoOverlay(_ isEnabled: Bool) {
        guard settings.showStreamInfoOverlay != isEnabled else { return }
        settings.showStreamInfoOverlay = isEnabled
        onSettingsChanged?(settings)
    }

    func setChannelProgramOverlayVisibility(_ visibility: ChannelProgramOverlayVisibility) {
        guard settings.channelProgramOverlayVisibility != visibility else { return }
        settings.channelProgramOverlayVisibility = visibility
        onSettingsChanged?(settings)
    }

    func setKeepFocusOnSingleLargeTile(_ isEnabled: Bool) {
        guard settings.keepFocusOnSingleLargeTile != isEnabled else { return }
        settings.keepFocusOnSingleLargeTile = isEnabled
        if isEnabled {
            focus(focusedIndex)
        }
        onSettingsChanged?(settings)
    }

    @discardableResult
    func applySettings(
        _ settings: AppSettings,
        tileLayout: TileLayoutConfig,
        channelSettings: ChannelSettings
    ) -> Bool {
        let mutedStatesByTileID = Dictionary(uniqueKeysWithValues: tiles.map { ($0.id, $0.isMuted) })
        guard applyTileLayout(tileLayout) else { return false }
        let normalizedVolume = VolumeLevel.normalized(settings.volumePercent)
        var settings = settings
        settings.volumePercent = normalizedVolume
        settings.keepFocusOnSingleLargeTile = settings.keepFocusOnSingleLargeTile ?? true
        settings.showStreamInfoOverlay = settings.showStreamInfoOverlay ?? false
        settings.channelProgramOverlayVisibility = settings.channelProgramOverlayVisibility ?? .onHover
        settings.followEventRelays = settings.followEventRelays ?? true
        settings.inferEventRelaysFromProgramGuide = settings.inferEventRelaysFromProgramGuide ?? false
        settings.programGenreDisplaySettings = settings.programGenreDisplaySettings
            ?? self.settings.programGenreDisplaySettings
            ?? .preset
        settings.largeTilePlayback = settings.largeTilePlayback
            ?? self.settings.largeTilePlayback
            ?? config.largeTilePlayback
            ?? TilePlaybackProfile.fallback
        settings.smallTilePlayback = settings.smallTilePlayback
            ?? self.settings.smallTilePlayback
            ?? config.smallTilePlayback
            ?? TilePlaybackProfile.fallback
        let previousBaseURL = config.epgStationBaseURL
        self.settings = settings
        self.channelSettings = channelSettings.normalized
        config = config.applying(settings)
        updateEPGStationClientIfNeeded(previousBaseURL: previousBaseURL)
        defaultVolumePercent = normalizedVolume
        applyPlaybackProfilesToTiles(restartPolicy: .whenPlaybackPipelineChanges)
        focus(focusedIndex)
        restoreMutedStates(mutedStatesByTileID)
        updateEventRelaySchedulingForSettings()
        onSettingsChanged?(settings)
        return true
    }

    func refreshCurrentPrograms() async {
        await channelCatalog?.refreshCurrentPrograms()
        notifyFocusedTitleChanged()
        updateInferredEventRelayMonitoring()
    }

    func channelProgramOverlayInfo(for tile: TileModel) -> ChannelProgramOverlayInfo? {
        guard let channelID = tile.stream?.channelID else { return nil }
        return channelCatalog?.overlayInfo(channelID: channelID)
    }

    func eventRelayOverlayText(for tile: TileModel) -> String? {
        guard let candidate = tile.eventRelayCandidate else {
            return tile.inferredEventRelayStatus
        }
        let targetNames = candidate.targets.map { target in
            if let item = channelCatalog?.item(
                networkId: target.networkId,
                serviceId: target.serviceId
            ) {
                return item.displayName
            }
            return "未登録 (NID \(hex(target.networkId)) / SID \(hex(target.serviceId)))"
        }
        var text = "relay target=\(targetNames.joined(separator: ", "))"
        if let sourceEnd = candidate.sourceEnd {
            text += " / end=\(sourceEnd.formatted(date: .omitted, time: .standard))"
        }
        return text
    }

    private func notifyFocusedTitleChanged() {
        onFocusedTitleChanged?(focusedWindowTitle)
    }

    private func hex(_ value: Int) -> String {
        "0x" + String(value, radix: 16)
    }

    private func restoreMutedStates(_ mutedStatesByTileID: [UUID: Bool]) {
        for tile in tiles {
            guard let isMuted = mutedStatesByTileID[tile.id] else { continue }
            tile.setMuted(isMuted)
        }
    }

    private func updateEPGStationClientIfNeeded(previousBaseURL: URL?) {
        guard config.epgStationBaseURL != previousBaseURL else { return }
        guard let epgStationBaseURL = config.epgStationBaseURL else {
            epgStationClient = nil
            channelCatalog = nil
            playbackModeOptions = [.fallback(mode: TilePlaybackProfile.fallback.liveStreamMode)]
            return
        }
        let client = EPGStationClient(baseURL: epgStationBaseURL)
        epgStationClient = client
        channelCatalog = ChannelCatalogModel(client: client)
        playbackModeOptions = [.fallback(mode: TilePlaybackProfile.fallback.liveStreamMode)]
    }

    private enum PlaybackProfileRestartPolicy {
        case whenPlaybackPipelineChanges
        case whenModeChanges
        case never
    }

    private func applyPlaybackProfilesToTiles(restartPolicy: PlaybackProfileRestartPolicy) {
        applyPlaybackProfilesToTiles(at: Array(tiles.indices), restartPolicy: restartPolicy)
    }

    private func applyPlaybackProfilesToTiles(
        at indices: [Int],
        restartPolicy: PlaybackProfileRestartPolicy
    ) {
        guard let epgStationClient else { return }
        for index in indices where tiles.indices.contains(index) {
            guard let stream = tiles[index].stream, let channelID = stream.channelID else { continue }
            let updatedStream = streamConfig(
                channelID: channelID,
                title: stream.title,
                tileIndex: index,
                epgStationClient: epgStationClient
            )
            if shouldRestartPlayback(
                currentStream: stream,
                updatedStream: updatedStream,
                policy: restartPolicy
            ) {
                tiles[index].play(stream: updatedStream)
            } else {
                tiles[index].updateStreamMetadata(
                    metadataStream(
                        currentStream: stream,
                        updatedStream: updatedStream,
                        policy: restartPolicy
                    )
                )
            }
        }
    }

    private func updatePlaybackMetadataForTiles() {
        applyPlaybackProfilesToTiles(restartPolicy: .never)
    }

    private func shouldRestartPlayback(
        currentStream: StreamConfig,
        updatedStream: StreamConfig,
        policy: PlaybackProfileRestartPolicy
    ) -> Bool {
        switch policy {
        case .whenPlaybackPipelineChanges:
            return !currentStream.hasSamePlaybackPipeline(as: updatedStream)
        case .whenModeChanges:
            return currentStream.playbackMode != updatedStream.playbackMode
        case .never:
            return false
        }
    }

    private func metadataStream(
        currentStream: StreamConfig,
        updatedStream: StreamConfig,
        policy: PlaybackProfileRestartPolicy
    ) -> StreamConfig {
        guard policy == .whenModeChanges else { return updatedStream }
        var metadata = updatedStream
        metadata.deinterlace = currentStream.deinterlace
        return metadata
    }

    @discardableResult
    func applyTileLayout(_ newLayout: TileLayoutConfig, focusFirstNewTile: Bool = false) -> Bool {
        let newLayout = newLayout.validOrFallback
        let oldCount = tiles.count
        let newCount = newLayout.tileCount
        guard newCount > 0 else { return false }

        if newCount < oldCount {
            for tile in tiles.suffix(oldCount - newCount) {
                disarmInferredEventRelay(for: tile.id)
                tile.clear()
            }
            tiles.removeLast(oldCount - newCount)
            focusedIndex = min(focusedIndex, tiles.count - 1)
        } else if newCount > oldCount {
            while tiles.count < newCount {
                let tile = TileModel(stream: nil, config: config, instance: instance)
                bindEventRelayCallbacks(to: tile)
                tiles.append(tile)
            }
            if focusFirstNewTile {
                focusedIndex = oldCount
            }
        }

        let oldLayout = layout
        layout = newLayout
        onLayoutChanged?(oldLayout, newLayout)
        focus(focusedIndex, forceAudioUpdate: focusFirstNewTile)
        return true
    }

    func shutdown() async {
        cancelAllEventRelayTasks()
        cancelAllInferredEventRelayTasks()
        await withTaskGroup(of: Void.self) { group in
            for tile in tiles {
                group.addTask { await tile.shutdown() }
            }
        }
    }

    private func bindEventRelayCallbacks(to tile: TileModel) {
        tile.onEventRelayCandidateChanged = { [weak self, weak tile] candidate in
            guard let tile else { return }
            self?.handleEventRelayCandidate(candidate, for: tile)
        }
        tile.onBroadcastClockChanged = { [weak self, weak tile] state in
            guard let tile else { return }
            self?.handleBroadcastClockChange(state, for: tile)
        }
    }

    private func handleEventRelayCandidate(_ candidate: EventRelayCandidate?, for tile: TileModel) {
        guard let candidate else {
            if let armed = armedEventRelays[tile.id],
               let sourceEnd = armed.candidate.sourceEnd,
               let clockState = tile.broadcastClockState,
               estimatedBroadcastDate(from: clockState) >= sourceEnd {
                performEventRelay(for: tile.id, generation: armed.generation)
                return
            }
            disarmEventRelay(for: tile.id)
            return
        }
        disarmInferredEventRelay(for: tile.id)
        guard settings.followEventRelays ?? true else {
            disarmEventRelay(for: tile.id)
            return
        }

        if let armed = armedEventRelays[tile.id],
           armed.candidate.sourceIdentity != candidate.sourceIdentity {
            if armed.candidate.sourceEnd != nil {
                performEventRelay(for: tile.id, generation: armed.generation)
                return
            }
            disarmEventRelay(for: tile.id)
        }
        armEventRelay(candidate, for: tile)
    }

    private func handleBroadcastClockChange(_ state: BroadcastClockState, for tile: TileModel) {
        guard let armed = armedEventRelays[tile.id],
              let sourceEnd = armed.candidate.sourceEnd
        else {
            return
        }
        if estimatedBroadcastDate(from: state) >= sourceEnd {
            performEventRelay(for: tile.id, generation: armed.generation)
        } else if armed.task == nil {
            scheduleEventRelay(for: tile)
        }
    }

    private func armEventRelay(_ candidate: EventRelayCandidate, for tile: TileModel) {
        disarmEventRelay(for: tile.id)
        let generation = UUID()
        armedEventRelays[tile.id] = ArmedEventRelay(
            candidate: candidate,
            generation: generation,
            task: nil
        )
        guard candidate.sourceEnd != nil else {
            tile.setEventRelayFollowStatus("relay follow=終了時刻未取得")
            return
        }
        scheduleEventRelay(for: tile)
    }

    private func scheduleEventRelay(for tile: TileModel) {
        guard var armed = armedEventRelays[tile.id],
              armed.task == nil,
              let sourceEnd = armed.candidate.sourceEnd,
              let clockState = tile.broadcastClockState
        else {
            return
        }

        let delay = sourceEnd.timeIntervalSince(estimatedBroadcastDate(from: clockState))
        if delay <= 0 {
            performEventRelay(for: tile.id, generation: armed.generation)
            return
        }

        let generation = armed.generation
        let tileID = tile.id
        armed.task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            self?.performEventRelay(for: tileID, generation: generation)
        }
        armedEventRelays[tile.id] = armed
    }

    private func performEventRelay(for tileID: UUID, generation: UUID) {
        guard let armed = armedEventRelays[tileID], armed.generation == generation else { return }
        armed.task?.cancel()
        armedEventRelays[tileID] = nil
        guard settings.followEventRelays ?? true,
              let tileIndex = tiles.firstIndex(where: { $0.id == tileID })
        else {
            return
        }

        let tile = tiles[tileIndex]
        guard let channelCatalog else {
            reportEventRelayFailure("チャンネル一覧未取得", for: tile)
            return
        }
        var seenChannelIDs = Set<Int>()
        let targetItems = armed.candidate.targets.compactMap { target in
            channelCatalog.item(networkId: target.networkId, serviceId: target.serviceId)
        }.filter { seenChannelIDs.insert($0.id).inserted }

        guard targetItems.count == 1, let target = targetItems.first else {
            let reason = targetItems.isEmpty
                ? "リレー先が見つかりません"
                : "リレー先を一意に決定できません (\(targetItems.count)件)"
            reportEventRelayFailure(reason, for: tile)
            return
        }
        guard target.id != tile.stream?.channelID else {
            tile.setEventRelayFollowStatus("relay follow=同一チャンネル")
            logEventRelay("same channel; skipped channelID=\(target.id)", tile: tile)
            return
        }
        followRelayTarget(target, at: tileIndex, kind: "EIT")
    }

    private func reportEventRelayFailure(_ reason: String, for tile: TileModel) {
        tile.setEventRelayFollowStatus("relay follow=\(reason)")
        logEventRelay("skipped: \(reason)", tile: tile)
    }

    private func followRelayTarget(
        _ target: ChannelSelectionItem,
        at tileIndex: Int,
        kind: String
    ) {
        guard tiles.indices.contains(tileIndex) else { return }
        let tile = tiles[tileIndex]
        guard let epgStationClient else {
            reportEventRelayFailure("EPGStation未設定", for: tile)
            return
        }
        let stream = streamConfig(
            channelID: target.id,
            title: target.displayName,
            tileIndex: tileIndex,
            epgStationClient: epgStationClient
        )
        let volumePercent = tile.volumePercent
        let wasMuted = tile.isMuted
        let previousChannelID = tile.stream?.channelID
        let previousChannelName = tile.stream?.title ?? previousChannelID.map(String.init) ?? "?"
        tile.play(stream: stream, initialVolumePercent: volumePercent)
        tile.setMuted(wasMuted)
        tile.setEventRelayFollowStatus(
            "relay followed=\(previousChannelName) -> \(target.displayName)"
        )
        if tileIndex == focusedIndex {
            notifyFocusedTitleChanged()
        }
        let previousChannelLabel = previousChannelID.map(String.init) ?? "?"
        let kindPrefix = kind == "EIT" ? "" : "\(kind) "
        logEventRelay(
            "\(kindPrefix)followed channelID=\(previousChannelLabel)->\(target.id)",
            tile: tile
        )
    }

    private func disarmEventRelay(for tileID: UUID) {
        armedEventRelays.removeValue(forKey: tileID)?.task?.cancel()
    }

    private func cancelAllEventRelayTasks() {
        for armed in armedEventRelays.values {
            armed.task?.cancel()
        }
        armedEventRelays.removeAll()
    }

    private func updateInferredEventRelayMonitoring() {
        guard settings.followEventRelays ?? true,
              settings.inferEventRelaysFromProgramGuide ?? false,
              let channelCatalog
        else {
            cancelAllInferredEventRelayTasks()
            return
        }

        let now = Date()
        var activeTileIDs = Set<UUID>()
        for tile in tiles {
            guard let channelID = tile.stream?.channelID else {
                disarmInferredEventRelay(for: tile.id)
                continue
            }
            guard tile.eventRelayCandidate == nil else {
                disarmInferredEventRelay(for: tile.id)
                continue
            }

            if let armed = armedInferredEventRelays[tile.id],
               armed.source.channelID == channelID,
               now >= armed.source.endAt.addingTimeInterval(-Self.inferredRelayFinalCheckLead),
               now <= armed.source.endAt.addingTimeInterval(1) {
                activeTileIDs.insert(tile.id)
                continue
            }

            guard let program = channelCatalog.item(channelID: channelID)?.currentProgram else {
                disarmInferredEventRelay(for: tile.id)
                continue
            }
            let remaining = program.endAt.timeIntervalSince(now)
            guard remaining > 0, remaining <= Self.inferredRelayLookahead else {
                disarmInferredEventRelay(for: tile.id)
                continue
            }

            activeTileIDs.insert(tile.id)
            let source = InferredEventRelaySource(
                programID: program.id,
                channelID: channelID,
                name: program.name,
                endAt: program.endAt
            )
            if armedInferredEventRelays[tile.id]?.source != source {
                armInferredEventRelay(source, for: tile)
            }
        }

        for tileID in Array(armedInferredEventRelays.keys) where !activeTileIDs.contains(tileID) {
            disarmInferredEventRelay(for: tileID)
        }
    }

    private func armInferredEventRelay(_ source: InferredEventRelaySource, for tile: TileModel) {
        disarmInferredEventRelay(for: tile.id)
        let generation = UUID()
        let tileID = tile.id
        armedInferredEventRelays[tileID] = ArmedInferredEventRelay(
            source: source,
            generation: generation,
            target: nil,
            task: nil
        )
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.monitorInferredEventRelay(
                source,
                tileID: tileID,
                generation: generation
            )
        }
        armedInferredEventRelays[tileID]?.task = task
    }

    private func monitorInferredEventRelay(
        _ source: InferredEventRelaySource,
        tileID: UUID,
        generation: UUID
    ) async {
        let finalCheckAt = source.endAt.addingTimeInterval(-Self.inferredRelayFinalCheckLead)

        while Date() < finalCheckAt {
            guard isInferredEventRelayActive(tileID: tileID, generation: generation) else { return }
            let resolution = await resolveInferredEventRelayTarget(for: source)
            guard isInferredEventRelayActive(tileID: tileID, generation: generation) else { return }
            updateInferredEventRelayOverlay(resolution, source: source, tileID: tileID)

            let delay = min(
                Self.inferredRelayRetryInterval,
                max(finalCheckAt.timeIntervalSinceNow, 0)
            )
            guard delay > 0 else { break }
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }

        guard isInferredEventRelayActive(tileID: tileID, generation: generation) else { return }
        let finalResolution = await resolveInferredEventRelayTarget(for: source)
        guard isInferredEventRelayActive(tileID: tileID, generation: generation) else { return }
        guard case let .target(target) = finalResolution else {
            if case let .unavailable(reason) = finalResolution,
               let tile = tiles.first(where: { $0.id == tileID }) {
                logEventRelay("inferred skipped: \(reason)", tile: tile)
            }
            finishInferredEventRelayMonitoring(tileID: tileID, generation: generation)
            return
        }
        updateInferredEventRelayOverlay(finalResolution, source: source, tileID: tileID)

        let delay = source.endAt.timeIntervalSinceNow
        if delay > 0 {
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
        }
        performInferredEventRelay(
            target,
            source: source,
            tileID: tileID,
            generation: generation
        )
    }

    private func resolveInferredEventRelayTarget(
        for source: InferredEventRelaySource
    ) async -> InferredEventRelayResolution {
        guard let epgStationClient, let channelCatalog else {
            return .unavailable("EPGStationまたはチャンネル一覧未取得")
        }

        do {
            let boundaryMargin: TimeInterval = 1
            let schedules = try await epgStationClient.fetchSchedules(
                startAt: source.endAt.addingTimeInterval(-boundaryMargin),
                endAt: source.endAt.addingTimeInterval(boundaryMargin)
            )
            let matchingPrograms = schedules
                .flatMap(\.programs)
                .filter {
                    $0.name == source.name
                        && Self.sameMillisecond($0.startAt, source.endAt)
                }

            if matchingPrograms.contains(where: { $0.channelId == source.channelID }) {
                return .unavailable("現チャンネルで同名番組が継続")
            }

            let externalChannelIDs = Set(
                matchingPrograms
                    .map(\.channelId)
                    .filter { $0 != source.channelID }
            )
            guard externalChannelIDs.count == 1, let targetChannelID = externalChannelIDs.first else {
                let reason = externalChannelIDs.isEmpty
                    ? "一致するリレー先なし"
                    : "一致するリレー先が複数 (\(externalChannelIDs.count)件)"
                return .unavailable(reason)
            }
            guard let item = channelCatalog.item(channelID: targetChannelID) else {
                return .unavailable("一致するリレー先がチャンネル一覧に未登録")
            }
            return .target(
                InferredEventRelayTarget(
                    channelID: item.id,
                    displayName: item.displayName
                )
            )
        } catch {
            return .unavailable("番組情報取得失敗: \(error.localizedDescription)")
        }
    }

    private func updateInferredEventRelayOverlay(
        _ resolution: InferredEventRelayResolution,
        source: InferredEventRelaySource,
        tileID: UUID
    ) {
        guard let tile = tiles.first(where: { $0.id == tileID }),
              var armed = armedInferredEventRelays[tileID]
        else {
            return
        }
        let previousTarget = armed.target
        switch resolution {
        case let .target(target):
            armed.target = target
            let end = source.endAt.formatted(date: .omitted, time: .standard)
            tile.setInferredEventRelayStatus(
                "relay inferred target=\(target.displayName) / end=\(end)"
            )
            if previousTarget != target {
                logEventRelay(
                    "inferred candidate target=\(target.displayName) channelID=\(target.channelID) end=\(source.endAt)",
                    tile: tile
                )
            }
        case .unavailable:
            armed.target = nil
            tile.setInferredEventRelayStatus(nil)
            if previousTarget != nil {
                logEventRelay("inferred candidate cleared", tile: tile)
            }
        }
        armedInferredEventRelays[tileID] = armed
    }

    private func performInferredEventRelay(
        _ target: InferredEventRelayTarget,
        source: InferredEventRelaySource,
        tileID: UUID,
        generation: UUID
    ) {
        guard isInferredEventRelayActive(tileID: tileID, generation: generation),
              let tileIndex = tiles.firstIndex(where: { $0.id == tileID }),
              tiles[tileIndex].stream?.channelID == source.channelID,
              let targetItem = channelCatalog?.item(channelID: target.channelID)
        else {
            return
        }
        armedInferredEventRelays[tileID] = nil
        tiles[tileIndex].setInferredEventRelayStatus(nil)
        followRelayTarget(targetItem, at: tileIndex, kind: "inferred")
    }

    private func isInferredEventRelayActive(tileID: UUID, generation: UUID) -> Bool {
        guard settings.followEventRelays ?? true,
              settings.inferEventRelaysFromProgramGuide ?? false,
              let armed = armedInferredEventRelays[tileID],
              armed.generation == generation,
              let tile = tiles.first(where: { $0.id == tileID }),
              tile.eventRelayCandidate == nil,
              tile.stream?.channelID == armed.source.channelID
        else {
            return false
        }
        return true
    }

    private func finishInferredEventRelayMonitoring(tileID: UUID, generation: UUID) {
        guard armedInferredEventRelays[tileID]?.generation == generation else { return }
        armedInferredEventRelays[tileID] = nil
        tiles.first(where: { $0.id == tileID })?.setInferredEventRelayStatus(nil)
    }

    private func disarmInferredEventRelay(for tileID: UUID) {
        armedInferredEventRelays.removeValue(forKey: tileID)?.task?.cancel()
        tiles.first(where: { $0.id == tileID })?.setInferredEventRelayStatus(nil)
    }

    private func cancelAllInferredEventRelayTasks() {
        let tileIDs = Array(armedInferredEventRelays.keys)
        for tileID in tileIDs {
            disarmInferredEventRelay(for: tileID)
        }
    }

    private static func sameMillisecond(_ lhs: Date, _ rhs: Date) -> Bool {
        Int64((lhs.timeIntervalSince1970 * 1_000).rounded())
            == Int64((rhs.timeIntervalSince1970 * 1_000).rounded())
    }

    private func updateEventRelaySchedulingForSettings() {
        cancelAllEventRelayTasks()
        cancelAllInferredEventRelayTasks()
        guard settings.followEventRelays ?? true else { return }
        for tile in tiles {
            if let candidate = tile.eventRelayCandidate {
                armEventRelay(candidate, for: tile)
            }
        }
        updateInferredEventRelayMonitoring()
    }

    private func estimatedBroadcastDate(from state: BroadcastClockState) -> Date {
        state.date.addingTimeInterval(Date().timeIntervalSince(state.receivedAt))
    }

    private func logEventRelay(_ message: String, tile: TileModel) {
        let label = tile.stream.map { $0.title ?? $0.url } ?? "empty tile"
        fputs("[event-relay] [\(label)] \(message)\n", stderr)
    }
}
