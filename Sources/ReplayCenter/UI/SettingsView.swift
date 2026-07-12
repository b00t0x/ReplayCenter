import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: TileGridModel
    let requiresEPGStationConnection: Bool
    let onClose: () -> Void
    @State private var selectedSection: SettingsSection = .general
    @State private var epgStationBaseURLText: String
    @State private var volumePercent: Int
    @State private var largeTilePlayback: TilePlaybackProfile
    @State private var smallTilePlayback: TilePlaybackProfile
    @State private var showStreamInfoOverlay: Bool
    @State private var showChannelProgramOverlayAlways: Bool
    @State private var followEventRelays: Bool
    @State private var highlightedProgramGenres: [ProgramGenreCode]
    @State private var dimmedProgramGenres: [ProgramGenreCode]
    @State private var draggingProgramGenre: ProgramGenreDragItem?
    @State private var isProgramGenrePickerPresented = false
    @State private var programGenrePickerTarget: ProgramGenreDisplayKind = .highlighted
    @State private var favoriteChannelIDs: [Int]
    @State private var hiddenChannelIDs: [Int]
    @State private var draggingFavoriteChannelID: Int?
    @State private var errorMessage: String?
    @State private var hasVerifiedEPGStationConnection: Bool
    @State private var isSaving = false

    init(
        model: TileGridModel,
        requiresEPGStationConnection: Bool = false,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.requiresEPGStationConnection = requiresEPGStationConnection
        self.onClose = onClose
        _epgStationBaseURLText = State(
            initialValue: model.settings.epgStationBaseURL?.absoluteString ?? ""
        )
        _volumePercent = State(initialValue: VolumeLevel.normalized(model.settings.volumePercent))
        _largeTilePlayback = State(
            initialValue: model.settings.largeTilePlayback ?? TilePlaybackProfile.fallback
        )
        _smallTilePlayback = State(
            initialValue: model.settings.smallTilePlayback ?? TilePlaybackProfile.fallback
        )
        _showStreamInfoOverlay = State(
            initialValue: model.settings.showStreamInfoOverlay ?? false
        )
        _showChannelProgramOverlayAlways = State(
            initialValue: (model.settings.channelProgramOverlayVisibility ?? .onHover) == .always
        )
        _followEventRelays = State(initialValue: model.settings.followEventRelays ?? true)
        let programGenreDisplaySettings = model.settings.programGenreDisplaySettings ?? .preset
        _highlightedProgramGenres = State(initialValue: programGenreDisplaySettings.highlightedGenres)
        _dimmedProgramGenres = State(initialValue: programGenreDisplaySettings.dimmedGenres)
        _favoriteChannelIDs = State(initialValue: model.channelSettings.favoriteChannelIDs)
        _hiddenChannelIDs = State(initialValue: model.channelSettings.hiddenChannelIDs)
        _hasVerifiedEPGStationConnection = State(initialValue: !requiresEPGStationConnection)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.54)
                .ignoresSafeArea()
                .onTapGesture {
                    if canClose {
                        onClose()
                    }
                }

            GeometryReader { proxy in
                let panelWidth = min(proxy.size.width, 960)
                let panelMaxHeight = min(panelWidth * 1.5, 860)
                settingsPanel
                    .frame(
                        width: panelWidth,
                        height: max(min(proxy.size.height, panelMaxHeight), 420)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .padding(20)
        }
        .onKeyPress(.escape) {
            if canClose {
                onClose()
            }
            return .handled
        }
        .task {
            await model.channelCatalog?.loadIfNeeded()
            updatePlaybackModeOptionsFromCatalog()
        }
    }

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

            Divider()

            HStack(spacing: 0) {
                sidebar
                    .frame(width: 180)

                Divider()

                ScrollView {
                    activeSection
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(20)
                }
            }

            Divider()

            footer
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 20)
    }

    private var header: some View {
        HStack {
            Text("設定")
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
            if canClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(SettingsSection.allCases) { section in
                Button {
                    selectedSection = section
                } label: {
                    HStack {
                        Image(systemName: section.systemImage)
                            .frame(width: 18)
                        Text(section.label)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        selectedSection == section
                            ? Color.accentColor.opacity(0.18)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSectionLocked(section))
                .opacity(isSectionLocked(section) ? 0.42 : 1)
            }
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private var activeSection: some View {
        switch selectedSection {
        case .general:
            generalSection
        case .playback:
            playbackSection
        case .genreDisplay:
            programDisplaySection
        case .channels:
            channelsSection
        }
    }

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("一般")

            VStack(alignment: .leading, spacing: 8) {
                Text("EPGStation")
                    .font(.headline)
                TextField("https://epgstation.example.local/", text: $epgStationBaseURLText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 520)
                if requiresEPGStationConnection {
                    Text("EPGStation に接続できる URL を保存すると、ほかの設定と視聴機能が使えるようになります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("再生")

            VStack(alignment: .leading, spacing: 10) {
                Text("音量の初期値")
                    .font(.headline)
                Stepper(
                    value: $volumePercent,
                    in: VolumeLevel.minimum...VolumeLevel.maximum,
                    step: VolumeLevel.step
                ) {
                    Text("\(volumePercent)%")
                        .font(.title3.monospacedDigit())
                        .frame(width: 72, alignment: .leading)
                }
                .frame(maxWidth: 220, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 8) {
                LeadingSwitchRow(
                    title: "ホバー時にストリーム情報を表示",
                    isOn: $showStreamInfoOverlay
                )
                LeadingSwitchRow(
                    title: "チャンネル/番組情報を常時表示",
                    isOn: $showChannelProgramOverlayAlways
                )
                LeadingSwitchRow(
                    title: "リレー中継を自動追従",
                    isOn: $followEventRelays
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("ストリーム")
                    .font(.headline)

                HStack(alignment: .top, spacing: 24) {
                    PlaybackProfileEditor(
                        title: "ラージタイル（またはタイル1枚）",
                        profile: $largeTilePlayback,
                        modeOptions: playbackModeOptions(including: largeTilePlayback.liveStreamMode)
                    )
                    PlaybackProfileEditor(
                        title: "スモールタイル",
                        profile: $smallTilePlayback,
                        modeOptions: playbackModeOptions(including: smallTilePlayback.liveStreamMode)
                    )
                }

                if let configErrorMessage = model.channelCatalog?.configErrorMessage {
                    Text("EPGStation 設定を取得できません: \(configErrorMessage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var programDisplaySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("ジャンル表示")

            HStack(alignment: .top, spacing: 18) {
                ProgramGenreSelectionList(
                    title: "強調表示",
                    emptyMessage: "強調表示するジャンルはありません",
                    kind: .highlighted,
                    codes: highlightedProgramGenres,
                    draggingProgramGenre: $draggingProgramGenre
                ) {
                    showProgramGenrePicker(for: .highlighted)
                } onRemove: { code in
                    removeProgramGenre(code, from: .highlighted)
                } onMoveUp: { code in
                    moveProgramGenre(code, in: .highlighted, by: -1)
                } onMoveDown: { code in
                    moveProgramGenre(code, in: .highlighted, by: 1)
                } onDrop: { source, target in
                    moveProgramGenre(source, toDropTarget: target, in: .highlighted)
                }

                ProgramGenreSelectionList(
                    title: "弱表示",
                    emptyMessage: "弱表示するジャンルはありません",
                    kind: .dimmed,
                    codes: dimmedProgramGenres,
                    draggingProgramGenre: $draggingProgramGenre
                ) {
                    showProgramGenrePicker(for: .dimmed)
                } onRemove: { code in
                    removeProgramGenre(code, from: .dimmed)
                } onMoveUp: { code in
                    moveProgramGenre(code, in: .dimmed, by: -1)
                } onMoveDown: { code in
                    moveProgramGenre(code, in: .dimmed, by: 1)
                } onDrop: { source, target in
                    moveProgramGenre(source, toDropTarget: target, in: .dimmed)
                }
            }

            HStack(spacing: 10) {
                Button("初期値に戻す") {
                    highlightedProgramGenres = ProgramGenreDisplaySettings.preset.highlightedGenres
                    dimmedProgramGenres = ProgramGenreDisplaySettings.preset.dimmedGenres
                }
                .buttonStyle(.bordered)

                Text("空にすると、その表示は無効になります。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if isProgramGenrePickerPresented {
                ProgramGenrePickerPanel(
                    target: programGenrePickerTarget,
                    highlightedGenres: highlightedProgramGenres,
                    dimmedGenres: dimmedProgramGenres
                ) { code in
                    addProgramGenre(code, to: programGenrePickerTarget)
                } onClose: {
                    isProgramGenrePickerPresented = false
                }
                .frame(maxWidth: 720)
            }
        }
    }

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("チャンネル管理")

            if let channelCatalog = model.channelCatalog {
                if channelCatalog.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let errorMessage = channelCatalog.errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.secondary)
                } else {
                    let rows = channelSettingsRows(for: channelCatalog.items)
                    if rows.isEmpty {
                        Text("チャンネルがありません")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(rows) { row in
                                let isFavorite = draftChannelSettings.containsFavorite(row.channelID)
                                let rowView = ChannelSettingsRow(
                                    row: row,
                                    isFavorite: isFavorite,
                                    isHidden: draftChannelSettings.containsHidden(row.channelID),
                                    canMoveUp: canMoveFavorite(row.channelID, by: -1),
                                    canMoveDown: canMoveFavorite(row.channelID, by: 1)
                                ) {
                                    setFavorite(!isFavorite, channelID: row.channelID)
                                } onToggleHidden: {
                                    setHidden(
                                        !draftChannelSettings.containsHidden(row.channelID),
                                        channelID: row.channelID
                                    )
                                } onMoveUp: {
                                    moveFavorite(channelID: row.channelID, by: -1)
                                } onMoveDown: {
                                    moveFavorite(channelID: row.channelID, by: 1)
                                }
                                if isFavorite {
                                    rowView
                                        .onDrag {
                                            draggingFavoriteChannelID = row.channelID
                                            return NSItemProvider(object: String(row.channelID) as NSString)
                                        }
                                        .onDrop(
                                            of: [UTType.text],
                                            delegate: FavoriteChannelDropDelegate(
                                                targetChannelID: row.channelID,
                                                favoriteChannelIDs: $favoriteChannelIDs,
                                                draggingFavoriteChannelID: $draggingFavoriteChannelID
                                            )
                                        )
                                } else {
                                    rowView
                                }
                                Divider()
                            }
                        }
                    }
                }
            } else {
                Text("EPGStation が未設定です")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer()
            if canClose {
                Button("キャンセル") {
                    onClose()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            Button(isSaving ? "確認中..." : "保存") {
                Task {
                    await save()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
            .disabled(isSaving)
        }
    }

    private var canClose: Bool {
        !requiresEPGStationConnection
    }

    private func isSectionLocked(_ section: SettingsSection) -> Bool {
        requiresEPGStationConnection
            && !hasVerifiedEPGStationConnection
            && section != .general
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title2)
            .fontWeight(.semibold)
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer {
            isSaving = false
        }

        updatePlaybackModeOptionsFromCatalog()
        let epgStationBaseURL = normalizedEPGStationBaseURL()
        if errorMessage != nil {
            return
        }
        guard let epgStationBaseURL else {
            errorMessage = "EPGStation URL を入力してください。"
            return
        }

        do {
            let config = try await EPGStationClient(baseURL: epgStationBaseURL).fetchConfig()
            let options = config.liveStreamModeOptions(for: model.liveStreamContainer)
            if !options.isEmpty {
                model.setPlaybackModeOptions(options)
            }
            hasVerifiedEPGStationConnection = true
        } catch {
            errorMessage = epgStationConnectionErrorMessage(error)
            return
        }

        let settings = AppSettings(
            epgStationBaseURL: epgStationBaseURL,
            volumePercent: VolumeLevel.normalized(volumePercent),
            keepFocusOnSingleLargeTile: model.settings.keepFocusOnSingleLargeTile ?? true,
            showStreamInfoOverlay: showStreamInfoOverlay,
            channelProgramOverlayVisibility: showChannelProgramOverlayAlways ? .always : .onHover,
            followEventRelays: followEventRelays,
            programGenreDisplaySettings: ProgramGenreDisplaySettings(
                highlightedGenres: highlightedProgramGenres,
                dimmedGenres: dimmedProgramGenres
            ),
            largeTilePlayback: largeTilePlayback,
            smallTilePlayback: smallTilePlayback
        )
        guard model.applySettings(
            settings,
            tileLayout: model.layout,
            channelSettings: draftChannelSettings
        ) else {
            errorMessage = "保存できませんでした。"
            return
        }
        if requiresEPGStationConnection {
            model.completeEPGStationSetup()
        } else {
            onClose()
        }
    }

    private func playbackModeOptions(including currentMode: Int) -> [EPGStationLiveStreamModeOption] {
        if let channelCatalog = model.channelCatalog {
            let catalogOptions = channelCatalog.playbackModeOptions(for: model.liveStreamContainer)
            if !catalogOptions.isEmpty {
                var options = catalogOptions
                if !options.contains(where: { $0.mode == currentMode }) {
                    options.append(.fallback(mode: currentMode))
                }
                return options.sorted { $0.mode < $1.mode }
            }
        }
        return model.playbackModeOptions(including: currentMode)
    }

    private func updatePlaybackModeOptionsFromCatalog() {
        guard let channelCatalog = model.channelCatalog else { return }
        model.setPlaybackModeOptions(channelCatalog.playbackModeOptions(for: model.liveStreamContainer))
    }

    private func normalizedEPGStationBaseURL() -> URL? {
        errorMessage = nil
        let trimmed = epgStationBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
            errorMessage = "EPGStation URL が正しくありません。"
            return nil
        }
        return url
    }

    private func epgStationConnectionErrorMessage(_ error: Error) -> String {
        var message = "EPGStation に接続できません: \(error.localizedDescription)"
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .timedOut:
                message += "\n初回起動時に macOS のローカルネットワークアクセスを許可した直後は、少し待ってからもう一度保存してください。"
            default:
                break
            }
        }
        return message
    }

    private var draftChannelSettings: ChannelSettings {
        ChannelSettings(
            favoriteChannelIDs: favoriteChannelIDs,
            hiddenChannelIDs: hiddenChannelIDs
        )
        .normalized
    }

    private func setFavorite(_ isFavorite: Bool, channelID: Int) {
        var settings = draftChannelSettings
        settings.setFavorite(isFavorite, channelID: channelID)
        favoriteChannelIDs = settings.favoriteChannelIDs
        hiddenChannelIDs = settings.hiddenChannelIDs
    }

    private func moveFavorite(channelID: Int, by offset: Int) {
        var settings = draftChannelSettings
        settings.moveFavorite(channelID: channelID, by: offset)
        favoriteChannelIDs = settings.favoriteChannelIDs
    }

    private func setHidden(_ isHidden: Bool, channelID: Int) {
        var settings = draftChannelSettings
        settings.setHidden(isHidden, channelID: channelID)
        favoriteChannelIDs = settings.favoriteChannelIDs
        hiddenChannelIDs = settings.hiddenChannelIDs
    }

    private func showProgramGenrePicker(for target: ProgramGenreDisplayKind) {
        programGenrePickerTarget = target
        isProgramGenrePickerPresented = true
    }

    private func addProgramGenre(_ code: ProgramGenreCode, to target: ProgramGenreDisplayKind) {
        removeProgramGenre(code, from: target.opposite)
        switch target {
        case .highlighted:
            if !highlightedProgramGenres.contains(code) {
                highlightedProgramGenres.append(code)
            }
        case .dimmed:
            if !dimmedProgramGenres.contains(code) {
                dimmedProgramGenres.append(code)
            }
        }
    }

    private func removeProgramGenre(_ code: ProgramGenreCode, from target: ProgramGenreDisplayKind) {
        switch target {
        case .highlighted:
            highlightedProgramGenres.removeAll { $0 == code }
        case .dimmed:
            dimmedProgramGenres.removeAll { $0 == code }
        }
    }

    private func moveProgramGenre(
        _ code: ProgramGenreCode,
        in target: ProgramGenreDisplayKind,
        by offset: Int
    ) {
        switch target {
        case .highlighted:
            highlightedProgramGenres.moveElement(code, by: offset)
        case .dimmed:
            dimmedProgramGenres.moveElement(code, by: offset)
        }
    }

    private func moveProgramGenre(
        _ source: ProgramGenreCode,
        toDropTarget targetCode: ProgramGenreCode,
        in target: ProgramGenreDisplayKind
    ) {
        switch target {
        case .highlighted:
            highlightedProgramGenres.moveElement(source, toDropTarget: targetCode)
        case .dimmed:
            dimmedProgramGenres.moveElement(source, toDropTarget: targetCode)
        }
    }

    private func canMoveFavorite(_ channelID: Int, by offset: Int) -> Bool {
        let ids = draftChannelSettings.favoriteChannelIDs
        guard let currentIndex = ids.firstIndex(of: channelID) else { return false }
        return ids.indices.contains(currentIndex + offset)
    }

    private func channelSettingsRows(for items: [ChannelSelectionItem]) -> [ChannelSettingsRowModel] {
        var itemsByID: [Int: ChannelSelectionItem] = [:]
        for item in items where itemsByID[item.id] == nil {
            itemsByID[item.id] = item
        }

        let favoriteIDs = draftChannelSettings.favoriteChannelIDs
        let favoriteIDSet = Set(favoriteIDs)
        let favoriteRows = favoriteIDs.map { channelID in
            if let item = itemsByID[channelID] {
                return ChannelSettingsRowModel(item: item)
            }
            return ChannelSettingsRowModel(missingChannelID: channelID)
        }
        let regularRows = items
            .filter { !favoriteIDSet.contains($0.id) }
            .map(ChannelSettingsRowModel.init(item:))
        return favoriteRows + regularRows
    }
}

private struct ChannelSettingsRowModel: Identifiable, Hashable {
    let channelID: Int
    let title: String
    let detail: String?
    let logoURL: URL?
    let isMissing: Bool

    var id: Int { channelID }

    init(item: ChannelSelectionItem) {
        self.channelID = item.id
        self.title = item.displayName
        self.detail = item.category.label
        self.logoURL = item.logoURL
        self.isMissing = false
    }

    init(missingChannelID channelID: Int) {
        self.channelID = channelID
        self.title = "不明なチャンネル"
        self.detail = "チャンネル情報を取得できません (ID: \(channelID))"
        self.logoURL = nil
        self.isMissing = true
    }
}

private enum ProgramGenreDisplayKind: String, CaseIterable, Identifiable {
    case highlighted
    case dimmed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .highlighted:
            return "強調表示"
        case .dimmed:
            return "弱表示"
        }
    }

    var addTitle: String {
        switch self {
        case .highlighted:
            return "強調表示するジャンルを追加"
        case .dimmed:
            return "表示を弱めるジャンルを追加"
        }
    }

    var shortLabel: String {
        switch self {
        case .highlighted:
            return "強調"
        case .dimmed:
            return "弱表示"
        }
    }

    var systemImage: String {
        switch self {
        case .highlighted:
            return "sparkles"
        case .dimmed:
            return "eye.slash"
        }
    }

    var accentColor: Color {
        switch self {
        case .highlighted:
            return .green
        case .dimmed:
            return .secondary
        }
    }

    var opposite: ProgramGenreDisplayKind {
        switch self {
        case .highlighted:
            return .dimmed
        case .dimmed:
            return .highlighted
        }
    }
}

private struct ProgramGenreDragItem: Equatable {
    let code: ProgramGenreCode
    let kind: ProgramGenreDisplayKind
}

private struct ProgramGenreSelectionList: View {
    let title: String
    let emptyMessage: String
    let kind: ProgramGenreDisplayKind
    let codes: [ProgramGenreCode]
    @Binding var draggingProgramGenre: ProgramGenreDragItem?
    let onAdd: () -> Void
    let onRemove: (ProgramGenreCode) -> Void
    let onMoveUp: (ProgramGenreCode) -> Void
    let onMoveDown: (ProgramGenreCode) -> Void
    let onDrop: (ProgramGenreCode, ProgramGenreCode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: kind.systemImage)
                    .font(.headline)
                Spacer()
                Button {
                    onAdd()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("\(title)するジャンルを追加")
            }

            VStack(spacing: 0) {
                if codes.isEmpty {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    ForEach(Array(codes.enumerated()), id: \.element.id) { index, code in
                        ProgramGenreSelectionRow(
                            code: code,
                            kind: kind,
                            canMoveUp: index > 0,
                            canMoveDown: index < codes.count - 1
                        ) {
                            onRemove(code)
                        } onMoveUp: {
                            onMoveUp(code)
                        } onMoveDown: {
                            onMoveDown(code)
                        }
                        .onDrag {
                            draggingProgramGenre = ProgramGenreDragItem(code: code, kind: kind)
                            return NSItemProvider(object: code.id as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: ProgramGenreDropDelegate(
                                targetCode: code,
                                targetKind: kind,
                                draggingProgramGenre: $draggingProgramGenre,
                                onDrop: onDrop
                            )
                        )

                        if index < codes.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .background(Color.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .frame(maxWidth: 320, alignment: .topLeading)
    }
}

private struct ProgramGenreSelectionRow: View {
    let code: ProgramGenreCode
    let kind: ProgramGenreDisplayKind
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onRemove: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(kind.accentColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                Text(option.title)
                    .font(.headline)
                    .lineLimit(1)
                if let detail = option.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                onMoveUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)
            .help("上へ移動")

            Button {
                onMoveDown()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(!canMoveDown)
            .help("下へ移動")

            Button {
                onRemove()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .help("削除")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var option: ProgramGenreOption {
        ProgramGenreCatalog.option(for: code)
    }
}

private struct ProgramGenrePickerPanel: View {
    let target: ProgramGenreDisplayKind
    let highlightedGenres: [ProgramGenreCode]
    let dimmedGenres: [ProgramGenreCode]
    let onAdd: (ProgramGenreCode) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(target.addTitle)
                    .font(.headline)
                Spacer()
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("閉じる")
            }

            VStack(spacing: 0) {
                ForEach(Array(ProgramGenreCatalog.genreOptions.enumerated()), id: \.element.id) { index, option in
                    ProgramGenrePickerGenreSection(
                        majorOption: option,
                        subGenreOptions: ProgramGenreCatalog.subGenreOptions(for: option.code.genre),
                        target: target,
                        selectionState: selectionState,
                        onAdd: onAdd
                    )

                    if index < ProgramGenreCatalog.genreOptions.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func selectionState(for code: ProgramGenreCode) -> ProgramGenreSelectionState {
        if highlightedGenres.contains(code) {
            return .highlighted
        }
        if dimmedGenres.contains(code) {
            return .dimmed
        }
        return .none
    }
}

private struct ProgramGenrePickerGenreSection: View {
    let majorOption: ProgramGenreOption
    let subGenreOptions: [ProgramGenreOption]
    let target: ProgramGenreDisplayKind
    let selectionState: (ProgramGenreCode) -> ProgramGenreSelectionState
    let onAdd: (ProgramGenreCode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ProgramGenrePickerRow(
                option: majorOption,
                selectionState: selectionState(majorOption.code),
                target: target,
                indent: 0,
                showsDetail: false
            ) {
                onAdd(majorOption.code)
            }

            ForEach(subGenreOptions) { option in
                ProgramGenrePickerRow(
                    option: option,
                    selectionState: selectionState(option.code),
                    target: target,
                    indent: 18,
                    showsDetail: false
                ) {
                    onAdd(option.code)
                }
            }
        }
    }
}

private struct ProgramGenrePickerRow: View {
    let option: ProgramGenreOption
    let selectionState: ProgramGenreSelectionState
    let target: ProgramGenreDisplayKind
    let indent: CGFloat
    let showsDetail: Bool
    let onAdd: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            if indent > 0 {
                Spacer()
                    .frame(width: indent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(option.title)
                    .font(indent == 0 ? .headline : .callout)
                    .lineLimit(1)
                if showsDetail, let detail = option.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let label = selectionState.label {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(selectionState.backgroundColor)
                    .foregroundStyle(selectionState.foregroundColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            Button {
                onAdd()
            } label: {
                Image(systemName: selectionState == target.state ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(addButtonBackground)
                    .foregroundStyle(addButtonForeground)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(selectionState == target.state)
            .help(selectionState == target.state ? "追加済み" : "\(target.label)に追加")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, showsDetail ? 8 : 6)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .onHover { isHovering = $0 }
    }

    private var rowBackground: Color {
        if isHovering {
            return Color.accentColor.opacity(0.12)
        }
        if indent == 0 {
            return Color.white.opacity(0.055)
        }
        return Color.white.opacity(0.025)
    }

    private var addButtonBackground: Color {
        if selectionState == target.state {
            return Color.secondary.opacity(0.16)
        }
        return Color.accentColor.opacity(isHovering ? 0.26 : 0.18)
    }

    private var addButtonForeground: Color {
        if selectionState == target.state {
            return .secondary
        }
        return .accentColor
    }
}

private enum ProgramGenreSelectionState: Equatable {
    case none
    case highlighted
    case dimmed

    var label: String? {
        switch self {
        case .none:
            return nil
        case .highlighted:
            return "強調"
        case .dimmed:
            return "弱表示"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .none:
            return .clear
        case .highlighted:
            return Color.green.opacity(0.72)
        case .dimmed:
            return Color.secondary.opacity(0.16)
        }
    }

    var foregroundColor: Color {
        switch self {
        case .none:
            return .clear
        case .highlighted:
            return .white
        case .dimmed:
            return .secondary
        }
    }
}

private extension ProgramGenreDisplayKind {
    var state: ProgramGenreSelectionState {
        switch self {
        case .highlighted:
            return .highlighted
        case .dimmed:
            return .dimmed
        }
    }
}

private struct ProgramGenreDropDelegate: DropDelegate {
    let targetCode: ProgramGenreCode
    let targetKind: ProgramGenreDisplayKind
    @Binding var draggingProgramGenre: ProgramGenreDragItem?
    let onDrop: (ProgramGenreCode, ProgramGenreCode) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingProgramGenre,
              draggingProgramGenre.kind == targetKind,
              draggingProgramGenre.code != targetCode
        else { return }
        onDrop(draggingProgramGenre.code, targetCode)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingProgramGenre = nil
        return true
    }
}

private struct PlaybackProfileEditor: View {
    let title: String
    @Binding var profile: TilePlaybackProfile
    let modeOptions: [EPGStationLiveStreamModeOption]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))

            Picker("方式", selection: $profile.liveStreamMode) {
                ForEach(modeOptions) { option in
                    Text(option.label).tag(option.mode)
                }
            }
            .frame(width: 220, alignment: .leading)

            Picker("インタレ解除", selection: $profile.deinterlace) {
                ForEach(deinterlaceOptions(for: profile.deinterlace), id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .frame(width: 220, alignment: .leading)
            .disabled(!allowsDeinterlace)
            .opacity(allowsDeinterlace ? 1 : 0.45)
        }
    }

    private var allowsDeinterlace: Bool {
        modeOptions.first { $0.mode == profile.liveStreamMode }?.isUnconverted == true
    }

    private func deinterlaceOptions(for currentValue: String) -> [(value: String, label: String)] {
        var options: [(value: String, label: String)] = [
            ("yadif", "yadif (30fps)"),
            ("yadif2x", "yadif2x (60fps)"),
            ("bob", "bob (60fps)"),
            ("linear", "linear (60fps)"),
            ("blend", "blend (30fps)"),
            ("auto", "auto"),
            ("off", "なし")
        ]
        if !options.contains(where: { $0.value == currentValue }) {
            let label = currentValue == "<unchanged>" ? "変更しない" : currentValue
            options.append((currentValue, label))
        }
        return options
    }
}

private struct ChannelSettingsRow: View {
    let row: ChannelSettingsRowModel
    let isFavorite: Bool
    let isHidden: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onToggleFavorite: () -> Void
    let onToggleHidden: () -> Void
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button {
                onToggleFavorite()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundStyle(isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
            .help(isFavorite ? "お気に入りから外す" : "お気に入りに追加")

            Button {
                onToggleHidden()
            } label: {
                Image(systemName: isHidden ? "eye.slash.fill" : "eye")
                    .foregroundStyle(isHidden ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .help(isHidden ? "選局画面に表示する" : "選局画面で非表示にする")

            SettingsChannelLogoView(url: row.logoURL, isMissing: row.isMissing)
                .opacity(isHidden ? 0.55 : 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if row.isMissing {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(row.title)
                        .lineLimit(1)
                        .strikethrough(isHidden)
                }
                    .font(.headline)
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(row.isMissing ? .orange : .secondary)
                        .lineLimit(1)
                        .strikethrough(isHidden)
                }
            }
            .opacity(isHidden ? 0.55 : 1)

            Spacer()

            Button {
                onMoveUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(!canMoveUp)

            Button {
                onMoveDown()
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(!canMoveDown)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct SettingsChannelLogoView: View {
    let url: URL?
    let isMissing: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlBackgroundColor))
            if isMissing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    case .failure:
                        placeholder
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 48, height: 32)
    }

    private var placeholder: some View {
        Image(systemName: "tv")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }
}

private struct FavoriteChannelDropDelegate: DropDelegate {
    let targetChannelID: Int
    @Binding var favoriteChannelIDs: [Int]
    @Binding var draggingFavoriteChannelID: Int?

    func dropEntered(info: DropInfo) {
        guard let draggingFavoriteChannelID,
              draggingFavoriteChannelID != targetChannelID
        else { return }
        var settings = ChannelSettings(favoriteChannelIDs: favoriteChannelIDs)
        settings.moveFavorite(channelID: draggingFavoriteChannelID, toDropTarget: targetChannelID)
        favoriteChannelIDs = settings.favoriteChannelIDs
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingFavoriteChannelID = nil
        return true
    }
}

struct TileLayoutQuickPickerPanel: View {
    let onSelect: (TileLayoutConfig) -> Void
    let onCancel: () -> Void
    let onKeepFocusOnSingleLargeTileChanged: (Bool) -> Void
    @State private var tileLayout: TileLayoutConfig
    @State private var category: TileLayoutCategory
    @State private var keepFocusOnSingleLargeTile: Bool

    init(
        currentLayout: TileLayoutConfig,
        keepFocusOnSingleLargeTile: Bool,
        onSelect: @escaping (TileLayoutConfig) -> Void,
        onCancel: @escaping () -> Void,
        onKeepFocusOnSingleLargeTileChanged: @escaping (Bool) -> Void
    ) {
        self.onSelect = onSelect
        self.onCancel = onCancel
        self.onKeepFocusOnSingleLargeTileChanged = onKeepFocusOnSingleLargeTileChanged
        _tileLayout = State(initialValue: currentLayout)
        _category = State(initialValue: TileLayoutCategory.category(for: currentLayout))
        _keepFocusOnSingleLargeTile = State(initialValue: keepFocusOnSingleLargeTile)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("タイル")
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
            }

            TileLayoutSettingsContent(
                tileLayout: $tileLayout,
                tileLayoutCategory: $category,
                keepFocusOnSingleLargeTile: Binding(
                    get: { keepFocusOnSingleLargeTile },
                    set: { newValue in
                        keepFocusOnSingleLargeTile = newValue
                        onKeepFocusOnSingleLargeTileChanged(newValue)
                    }
                )
            ) { layout in
                onSelect(layout)
            }
        }
        .padding(20)
        .frame(width: 900, height: 540, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 20)
    }
}

private struct TileLayoutSettingsContent: View {
    @Binding var tileLayout: TileLayoutConfig
    @Binding var tileLayoutCategory: TileLayoutCategory
    @Binding var keepFocusOnSingleLargeTile: Bool
    var onLayoutSelected: ((TileLayoutConfig) -> Void)?

    private let columns = Array(
        repeating: GridItem(.fixed(126), spacing: 12),
        count: 6
    )
    private let gridReservedHeight: CGFloat = 336

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            LeadingSwitchRow(
                title: "フォーカス時にラージタイルへ入れ替え",
                detail: "ラージタイルが1枚だけの配置で有効です。",
                isOn: $keepFocusOnSingleLargeTile
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("配置")
                    .font(.headline)
                Picker("配置カテゴリ", selection: $tileLayoutCategory) {
                    ForEach(TileLayoutCategory.allCases) { category in
                        Text(category.label).tag(category)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 420)

                LazyVGrid(
                    columns: columns,
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(tileLayoutCategory.layouts, id: \.self) { layout in
                        TileLayoutOptionView(
                            layout: layout,
                            isSelected: tileLayout.hasSameShape(as: layout)
                        ) {
                            tileLayout = layout
                            onLayoutSelected?(layout)
                        }
                    }
                }
                .frame(height: gridReservedHeight, alignment: .topLeading)
            }
        }
    }
}

private enum TileLayoutCategory: String, CaseIterable, Identifiable {
    case uniform
    case singleLarge
    case multipleLarge

    var id: String { rawValue }

    var label: String {
        switch self {
        case .uniform:
            return "均等配置"
        case .singleLarge:
            return "大小タイル"
        case .multipleLarge:
            return "ラージタイル複数"
        }
    }

    var layouts: [TileLayoutConfig] {
        switch self {
        case .uniform:
            return TileLayoutConfig.uniformPresets
        case .singleLarge:
            return TileLayoutConfig.singleLargePresets
        case .multipleLarge:
            return TileLayoutConfig.multipleLargePresets
        }
    }

    static func category(for layout: TileLayoutConfig) -> TileLayoutCategory {
        if layout.tileCount == 1 {
            return .uniform
        }
        if layout.uiLargeTileCount > 1 {
            return .multipleLarge
        }
        if layout.uiLargeTileCount == 1 {
            return .singleLarge
        }
        return .uniform
    }
}

private struct TileLayoutOptionView: View {
    let layout: TileLayoutConfig
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                TileLayoutPreview(layout: layout)
                    .frame(width: 108, height: 68)
                    .frame(maxWidth: .infinity, alignment: .center)

                HStack(spacing: 5) {
                    Text(layout.optionSummary)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(layout.tileCount)枚")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.18) : Color.white.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.16), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(layout.optionSummary)
    }
}

private struct TileLayoutPreview: View {
    let layout: TileLayoutConfig

    var body: some View {
        GeometryReader { proxy in
            let previewSize = fittedSize(in: proxy.size)
            let cellWidth = previewSize.width / CGFloat(layout.columns)
            let cellHeight = previewSize.height / CGFloat(layout.rows)

            ZStack(alignment: .topLeading) {
                ForEach(Array(layout.placements.enumerated()), id: \.offset) { _, placement in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(tileColor(for: placement))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(Color.white.opacity(0.35), lineWidth: 0.8)
                        }
                        .frame(
                            width: max(cellWidth * CGFloat(placement.width) - 2, 1),
                            height: max(cellHeight * CGFloat(placement.height) - 2, 1)
                        )
                        .position(
                            x: cellWidth * (CGFloat(placement.x) + CGFloat(placement.width) / 2),
                            y: cellHeight * (CGFloat(placement.y) + CGFloat(placement.height) / 2)
                        )
                }
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
        }
    }

    private func fittedSize(in availableSize: CGSize) -> CGSize {
        guard availableSize.width > 0, availableSize.height > 0 else { return .zero }
        let aspect = CGFloat(layout.columns * 16) / CGFloat(layout.rows * 9)
        let availableAspect = availableSize.width / availableSize.height
        if availableAspect > aspect {
            return CGSize(width: availableSize.height * aspect, height: availableSize.height)
        }
        return CGSize(width: availableSize.width, height: availableSize.width / aspect)
    }

    private func tileColor(for placement: TilePlacement) -> Color {
        if placement.width > 1 || placement.height > 1 {
            return Color.accentColor.opacity(0.72)
        }
        return Color.primary.opacity(0.18)
    }
}

private struct LeadingSwitchRow: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case playback
    case channels
    case genreDisplay

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:
            return "一般"
        case .playback:
            return "再生"
        case .channels:
            return "チャンネル管理"
        case .genreDisplay:
            return "ジャンル表示"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .playback:
            return "play.rectangle"
        case .channels:
            return "list.bullet"
        case .genreDisplay:
            return "tag"
        }
    }
}

private extension Array where Element: Equatable {
    mutating func moveElement(_ element: Element, by offset: Int) {
        guard let currentIndex = firstIndex(of: element) else { return }
        let targetIndex = currentIndex + offset
        guard indices.contains(targetIndex) else { return }
        remove(at: currentIndex)
        insert(element, at: targetIndex)
    }

    mutating func moveElement(_ source: Element, toDropTarget target: Element) {
        guard source != target,
              let sourceIndex = firstIndex(of: source),
              let targetIndex = firstIndex(of: target)
        else { return }
        remove(at: sourceIndex)
        let adjustedTargetIndex = sourceIndex < targetIndex ? targetIndex - 1 : targetIndex
        insert(source, at: adjustedTargetIndex)
    }
}
