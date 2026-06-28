import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: TileGridModel
    let onClose: () -> Void
    @State private var selectedSection: SettingsSection = .general
    @State private var epgStationBaseURLText: String
    @State private var volumePercent: Int
    @State private var largeTilePlayback: TilePlaybackProfile
    @State private var smallTilePlayback: TilePlaybackProfile
    @State private var tileLayout: TileLayoutConfig
    @State private var tileLayoutCategory: TileLayoutCategory
    @State private var keepFocusOnSingleLargeTile: Bool
    @State private var showStreamInfoOverlay: Bool
    @State private var favoriteChannelIDs: [Int]
    @State private var hiddenChannelIDs: [Int]
    @State private var draggingFavoriteChannelID: Int?
    @State private var errorMessage: String?

    init(
        model: TileGridModel,
        onClose: @escaping () -> Void
    ) {
        self.model = model
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
        _tileLayout = State(initialValue: model.layout)
        _tileLayoutCategory = State(initialValue: TileLayoutCategory.category(for: model.layout))
        _keepFocusOnSingleLargeTile = State(
            initialValue: model.settings.keepFocusOnSingleLargeTile ?? true
        )
        _showStreamInfoOverlay = State(
            initialValue: model.settings.showStreamInfoOverlay ?? true
        )
        _favoriteChannelIDs = State(initialValue: model.channelSettings.favoriteChannelIDs)
        _hiddenChannelIDs = State(initialValue: model.channelSettings.hiddenChannelIDs)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.54)
                .ignoresSafeArea()
                .onTapGesture {
                    onClose()
                }

            GeometryReader { proxy in
                settingsPanel
                    .frame(
                        width: max(min(proxy.size.width - 40, 1120), 420),
                        height: max(min(proxy.size.height - 40, 760), 420)
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .padding(20)
        }
        .onKeyPress(.escape) {
            onClose()
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 20)
    }

    private var header: some View {
        HStack {
            Text("設定")
                .font(.title3)
                .fontWeight(.semibold)
            Spacer()
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
        case .tiles:
            tilesSection
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
            }
        }
    }

    private var playbackSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("再生")

            VStack(alignment: .leading, spacing: 10) {
                Text("音量")
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

            Toggle("ホバー時にストリーム情報を表示", isOn: $showStreamInfoOverlay)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 12) {
                Text("ストリーム")
                    .font(.headline)

                HStack(alignment: .top, spacing: 24) {
                    PlaybackProfileEditor(
                        title: "ラージタイル",
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

    private var tilesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("タイル")

            Toggle("フォーカス時にラージタイルへ入れ替え", isOn: $keepFocusOnSingleLargeTile)
                .toggleStyle(.switch)

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
                    columns: [GridItem(.adaptive(minimum: 126, maximum: 160), spacing: 12)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(tileLayoutCategory.layouts, id: \.self) { layout in
                        TileLayoutOptionView(
                            layout: layout,
                            isSelected: tileLayout.hasSameShape(as: layout)
                        ) {
                            tileLayout = layout
                        }
                    }
                }
            }
        }
    }

    private var channelsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("チャンネル")

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
            Button("キャンセル") {
                onClose()
            }
            .keyboardShortcut(.escape, modifiers: [])
            Button("保存") {
                save()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: [])
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.title2)
            .fontWeight(.semibold)
    }

    private func save() {
        updatePlaybackModeOptionsFromCatalog()
        let epgStationBaseURL = normalizedEPGStationBaseURL()
        if errorMessage != nil {
            return
        }
        let settings = AppSettings(
            epgStationBaseURL: epgStationBaseURL,
            volumePercent: VolumeLevel.normalized(volumePercent),
            keepFocusOnSingleLargeTile: keepFocusOnSingleLargeTile,
            showStreamInfoOverlay: showStreamInfoOverlay,
            largeTilePlayback: largeTilePlayback,
            smallTilePlayback: smallTilePlayback
        )
        guard model.applySettings(
            settings,
            tileLayout: tileLayout,
            channelSettings: draftChannelSettings
        ) else {
            errorMessage = "保存できませんでした。"
            return
        }
        onClose()
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
    }

    private func moveFavorite(channelID: Int, by offset: Int) {
        var settings = draftChannelSettings
        settings.moveFavorite(channelID: channelID, by: offset)
        favoriteChannelIDs = settings.favoriteChannelIDs
    }

    private func setHidden(_ isHidden: Bool, channelID: Int) {
        var settings = draftChannelSettings
        settings.setHidden(isHidden, channelID: channelID)
        hiddenChannelIDs = settings.hiddenChannelIDs
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
    let isMissing: Bool

    var id: Int { channelID }

    init(item: ChannelSelectionItem) {
        self.channelID = item.id
        self.title = item.displayName
        self.detail = item.category.label
        self.isMissing = false
    }

    init(missingChannelID channelID: Int) {
        self.channelID = channelID
        self.title = "不明なチャンネル"
        self.detail = "チャンネル情報を取得できません (ID: \(channelID))"
        self.isMissing = true
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
            ("yadif", "yadif"),
            ("bob", "bob"),
            ("linear", "linear"),
            ("blend", "blend"),
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
                onToggleHidden()
            } label: {
                Image(systemName: isHidden ? "eye.slash.fill" : "eye")
                    .foregroundStyle(isHidden ? .secondary : .primary)
            }
            .buttonStyle(.plain)
            .help(isHidden ? "選局画面に表示する" : "選局画面で非表示にする")

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
            return "複数大"
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
        if layout.tileCount == 1 || placement.width > 1 || placement.height > 1 {
            return Color.accentColor.opacity(0.72)
        }
        return Color.white.opacity(0.3)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case playback
    case tiles
    case channels

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general:
            return "一般"
        case .playback:
            return "再生"
        case .tiles:
            return "タイル"
        case .channels:
            return "チャンネル"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .playback:
            return "play.rectangle"
        case .tiles:
            return "rectangle.grid.3x2"
        case .channels:
            return "list.bullet"
        }
    }
}
