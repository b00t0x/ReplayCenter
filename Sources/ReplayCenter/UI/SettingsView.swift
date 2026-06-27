import SwiftUI

struct SettingsView: View {
    @Bindable var model: TileGridModel
    let channelCatalog: ChannelCatalogModel?
    let onClose: () -> Void
    @State private var selectedSection: SettingsSection = .general
    @State private var startupStreams: StartupStreamsMode
    @State private var volumePercent: Int
    @State private var tileLayout: TileLayoutConfig
    @State private var tileLayoutCategory: TileLayoutCategory
    @State private var favoriteChannelIDs: [Int]
    @State private var errorMessage: String?

    init(
        model: TileGridModel,
        channelCatalog: ChannelCatalogModel?,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.channelCatalog = channelCatalog
        self.onClose = onClose
        _startupStreams = State(initialValue: model.settings.startupStreams ?? .configured)
        _volumePercent = State(initialValue: VolumeLevel.normalized(model.settings.volumePercent))
        _tileLayout = State(initialValue: model.layout)
        _tileLayoutCategory = State(initialValue: TileLayoutCategory.category(for: model.layout))
        _favoriteChannelIDs = State(initialValue: model.channelSettings.favoriteChannelIDs)
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
                        width: max(min(proxy.size.width - 40, 1040), 320),
                        height: max(min(proxy.size.height - 40, 720), 360)
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
            await channelCatalog?.loadIfNeeded()
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

            VStack(alignment: .leading, spacing: 10) {
                Text("起動時ストリーム")
                    .font(.headline)
                Picker("起動時ストリーム", selection: $startupStreams) {
                    Text("設定ファイル").tag(StartupStreamsMode.configured)
                    Text("空").tag(StartupStreamsMode.empty)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
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
        }
    }

    private var tilesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("タイル")

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

            if let channelCatalog {
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
                                ChannelSettingsRow(
                                    row: row,
                                    isFavorite: draftChannelSettings.containsFavorite(row.channelID),
                                    canMoveUp: canMoveFavorite(row.channelID, by: -1),
                                    canMoveDown: canMoveFavorite(row.channelID, by: 1)
                                ) {
                                    setFavorite(
                                        !draftChannelSettings.containsFavorite(row.channelID),
                                        channelID: row.channelID
                                    )
                                } onMoveUp: {
                                    moveFavorite(channelID: row.channelID, by: -1)
                                } onMoveDown: {
                                    moveFavorite(channelID: row.channelID, by: 1)
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
        let settings = AppSettings(
            startupStreams: startupStreams,
            volumePercent: VolumeLevel.normalized(volumePercent)
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

    private var draftChannelSettings: ChannelSettings {
        ChannelSettings(favoriteChannelIDs: favoriteChannelIDs).normalized
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
        self.title = item.channel.name
        self.detail = item.currentProgram?.name
        self.isMissing = false
    }

    init(missingChannelID channelID: Int) {
        self.channelID = channelID
        self.title = "不明なチャンネル"
        self.detail = "チャンネル情報を取得できません (ID: \(channelID))"
        self.isMissing = true
    }
}

private struct ChannelSettingsRow: View {
    let row: ChannelSettingsRowModel
    let isFavorite: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onToggleFavorite: () -> Void
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
                }
                    .font(.headline)
                if let detail = row.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(row.isMissing ? .orange : .secondary)
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

private enum TileLayoutCategory: String, CaseIterable, Identifiable {
    case standard
    case wideTall
    case large

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard:
            return "標準"
        case .wideTall:
            return "縦横"
        case .large:
            return "ラージ"
        }
    }

    var layouts: [TileLayoutConfig] {
        switch self {
        case .standard:
            return TileLayoutConfig.standardPresets
        case .wideTall:
            return TileLayoutConfig.wideTallPresets
        case .large:
            return TileLayoutConfig.largePresets
        }
    }

    static func category(for layout: TileLayoutConfig) -> TileLayoutCategory {
        if large.layouts.contains(where: { layout.hasSameShape(as: $0) }) {
            return .large
        }
        if wideTall.layouts.contains(where: { layout.hasSameShape(as: $0) }) {
            return .wideTall
        }
        return .standard
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
                    Text(layout.summary)
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
        .help(layout.summary)
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
