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
    @State private var scrollTargetItemID: ChannelSelectionItem.ID?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.54)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

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
            .frame(width: 520, height: 560)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 20)
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
                    ForEach(filteredItems) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            ChannelSelectionRow(
                                item: item,
                                selected: selectedItemID == item.id
                            )
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                        .onHover { isHovering in
                            if isHovering {
                                selectedItemID = item.id
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

    private func moveSelection(by offset: Int) {
        guard !filteredItems.isEmpty else { return }
        let currentIndex = selectedItemID.flatMap { selectedItemID in
            filteredItems.firstIndex { $0.id == selectedItemID }
        } ?? 0
        let nextIndex = min(max(currentIndex + offset, 0), filteredItems.count - 1)
        selectedItemID = filteredItems[nextIndex].id
        scrollTargetItemID = selectedItemID
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
            scrollTargetItemID = selectedItemID
        }
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
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.headline)
                    .lineLimit(1)

                if let program = item.currentProgram {
                    Text("\(program.timeRangeText)  \(program.name)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("放送中番組なし")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(selected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
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
