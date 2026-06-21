import SwiftUI

struct ChannelSelectorView: View {
    @Bindable var catalog: ChannelCatalogModel
    let onSelect: (ChannelSelectionItem) -> Void
    let onCancel: () -> Void
    @State private var searchText = ""

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

                if catalog.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else if let errorMessage = catalog.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    List(filteredItems) { item in
                        Button {
                            onSelect(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.channel.name)
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .frame(width: 520, height: 560)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 20)
        }
    }

    private var filteredItems: [ChannelSelectionItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return catalog.items }

        return catalog.items.filter { item in
            item.channel.name.localizedCaseInsensitiveContains(query)
                || item.currentProgram?.name.localizedCaseInsensitiveContains(query) == true
        }
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
