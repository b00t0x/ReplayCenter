import AppKit
import SwiftUI

struct ChannelSelectorView: View {
    @Bindable var catalog: ChannelCatalogModel
    let channelSettings: ChannelSettings
    let onSelect: (ChannelSelectionItem) -> Void
    let onCancel: () -> Void
    @State private var searchText = ""
    @State private var selectedTab: ChannelSelectorTab = .favorites
    @State private var selectedItemID: ChannelSelectionItem.ID?
    @State private var scrollTargetItemID: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.54)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            GeometryReader { proxy in
                VStack(spacing: 0) {
                    HStack {
                        TextField("チャンネル検索", text: $searchText)
                            .textFieldStyle(.roundedBorder)
                            .focused($isSearchFocused)
                            .onSubmit {
                                selectHighlightedItem()
                            }

                        Button("更新") {
                            Task {
                                await catalog.reload()
                            }
                        }

                        Button("閉じる") {
                            onCancel()
                        }
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                    .padding(12)

                    Picker("分類", selection: $selectedTab) {
                        ForEach(ChannelSelectorTab.allCases) { tab in
                            Text(tab.label).tag(tab)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)

                    if catalog.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else if let errorMessage = catalog.errorMessage {
                        Text(errorMessage)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        channelList
                    }
                }
                .frame(width: 520, height: channelSelectorHeight(in: proxy.size))
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(radius: 20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .padding(20)
        }
        .onAppear {
            selectFirstFilteredItem(scrollToSelection: false)
            isSearchFocused = true
        }
        .onChange(of: searchText) {
            selectFirstFilteredItem(scrollToSelection: true)
        }
        .onChange(of: selectedTab) {
            selectFirstFilteredItem(scrollToSelection: true)
        }
        .onChange(of: catalog.items) {
            selectFirstFilteredItem(scrollToSelection: true)
        }
        .onKeyPress(.upArrow) {
            moveSelection(by: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(by: 1)
            return .handled
        }
        .onKeyPress(.return) {
            selectHighlightedItem()
            return .handled
        }
    }

    private var channelList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredSections) { section in
                        if let title = section.title {
                            Text(title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(Color(nsColor: .controlBackgroundColor))
                        }
                        ForEach(section.items) { item in
                            Button {
                                onSelect(item)
                            } label: {
                                ChannelSelectionRow(
                                    item: item,
                                    selected: selectedItemID == item.id
                                )
                            }
                            .buttonStyle(.plain)
                            .id(rowID(for: item.id))
                            .onHover { isHovering in
                                if isHovering {
                                    selectedItemID = item.id
                                }
                            }
                        }
                    }
                }
            }
            .onChange(of: scrollTargetItemID) {
                if let scrollTargetItemID {
                    proxy.scrollTo(scrollTargetItemID, anchor: .center)
                }
            }
        }
    }

    private var filteredItems: [ChannelSelectionItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let orderedItems = selectedTab.items(
            from: channelSettings.orderedItems(catalog.items),
            channelSettings: channelSettings
        )
        let items: [ChannelSelectionItem]
        if query.isEmpty {
            items = orderedItems
        } else {
            items = orderedItems.filter { item in
                item.displayName.localizedCaseInsensitiveContains(query)
                    || item.currentProgram?.name.localizedCaseInsensitiveContains(query) == true
            }
        }
        return items
    }

    private var filteredSections: [ChannelSelectorSection] {
        guard selectedTab != .favorites else {
            return [ChannelSelectorSection(title: nil, items: filteredItems)]
        }
        let currentProgramItems = filteredItems.filter { $0.currentProgram != nil }
        let noProgramItems = filteredItems.filter { $0.currentProgram == nil }
        return [
            ChannelSelectorSection(title: "放送中", items: currentProgramItems),
            ChannelSelectorSection(title: "番組情報なし", items: noProgramItems)
        ]
        .filter { !$0.items.isEmpty }
    }

    private func channelSelectorHeight(in availableSize: CGSize) -> CGFloat {
        let availableHeight = max(availableSize.height - 40, 560)
        return min(availableHeight, 760)
    }

    private func moveSelection(by offset: Int) {
        guard !filteredItems.isEmpty else { return }
        let currentIndex = selectedItemID.flatMap { selectedItemID in
            filteredItems.firstIndex { $0.id == selectedItemID }
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), filteredItems.count - 1)
        selectedItemID = filteredItems[nextIndex].id
        scrollTargetItemID = rowID(for: filteredItems[nextIndex].id)
    }

    private func selectHighlightedItem() {
        guard let item = selectedItem ?? filteredItems.first else { return }
        onSelect(item)
    }

    private var selectedItem: ChannelSelectionItem? {
        guard let selectedItemID else { return nil }
        return filteredItems.first { $0.id == selectedItemID }
    }

    private func selectFirstFilteredItem(scrollToSelection: Bool) {
        selectedItemID = filteredItems.first?.id
        if scrollToSelection {
            scrollTargetItemID = selectedItemID.map(rowID)
        }
    }

    private func rowID(for itemID: ChannelSelectionItem.ID) -> String {
        "\(selectedTab.rawValue)-\(itemID)"
    }
}

private struct ChannelSelectorSection: Identifiable {
    let title: String?
    let items: [ChannelSelectionItem]

    var id: String {
        title ?? "all"
    }
}

private enum ChannelSelectorTab: String, CaseIterable, Identifiable {
    case favorites
    case terrestrial
    case bs
    case cs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .favorites:
            return "お気に入り"
        case .terrestrial:
            return "地上波"
        case .bs:
            return "BS"
        case .cs:
            return "CS"
        }
    }

    func items(
        from items: [ChannelSelectionItem],
        channelSettings: ChannelSettings
    ) -> [ChannelSelectionItem] {
        switch self {
        case .favorites:
            return items.filter { channelSettings.containsFavorite($0.id) }
        case .terrestrial:
            return items.filter { $0.category == .terrestrial }
        case .bs:
            return items.filter { $0.category == .bs }
        case .cs:
            return items.filter { $0.category == .cs }
        }
    }
}

private struct ChannelSelectionRow: View {
    let item: ChannelSelectionItem
    let selected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ChannelLogoView(url: item.logoURL)
                .opacity(contentOpacity)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(titleFont)
                        .lineLimit(1)
                        .opacity(contentOpacity)

                    if programStyle != .normal {
                        ChannelProgramStyleBadge(style: programStyle)
                    }
                }

                if let program = item.currentProgram {
                    Text("\(program.timeRangeText)  \(program.name)")
                        .font(.caption)
                        .foregroundStyle(programTextStyle)
                        .lineLimit(1)
                        .opacity(contentOpacity)
                } else {
                    Text("番組情報なし")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if programStyle == .baseball {
                Rectangle()
                    .fill(Color.green.opacity(selected ? 0.72 : 0.5))
                    .frame(width: 3)
            }
        }
        .contentShape(Rectangle())
    }

    private var programStyle: ChannelProgramStyle {
        item.currentProgram?.channelSelectorStyle ?? .normal
    }

    private var titleFont: Font {
        programStyle == .baseball ? .headline.weight(.bold) : .headline
    }

    private var programTextStyle: HierarchicalShapeStyle {
        switch programStyle {
        case .baseball:
            return .primary
        case .shopping:
            return .tertiary
        case .normal:
            return .secondary
        }
    }

    private var contentOpacity: Double {
        programStyle == .shopping && !selected ? 0.48 : 1
    }

    private var rowBackground: Color {
        if selected {
            return Color.accentColor.opacity(programStyle == .baseball ? 0.24 : 0.18)
        }
        if programStyle == .baseball {
            return Color.green.opacity(0.1)
        }
        return .clear
    }
}

private struct ChannelProgramStyleBadge: View {
    let style: ChannelProgramStyle

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var label: String {
        switch style {
        case .baseball:
            return "野球"
        case .shopping:
            return "通販"
        case .normal:
            return ""
        }
    }

    private var backgroundColor: Color {
        switch style {
        case .baseball:
            return Color.green.opacity(0.72)
        case .shopping:
            return Color.secondary.opacity(0.16)
        case .normal:
            return .clear
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .baseball:
            return .white
        case .shopping:
            return .secondary
        case .normal:
            return .clear
        }
    }
}

private struct ChannelLogoView: View {
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlBackgroundColor))
            if let url {
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

private extension ScheduleProgram {
    var timeRangeText: String {
        "\(Self.timeFormatter.string(from: startAt))-\(Self.timeFormatter.string(from: endAt))"
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
