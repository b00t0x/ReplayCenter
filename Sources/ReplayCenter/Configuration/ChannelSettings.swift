import Foundation

struct ChannelSettings: Codable, Equatable {
    var favoriteChannelIDs: [Int]
    var hiddenChannelIDs: [Int]

    static let empty = ChannelSettings()

    init(favoriteChannelIDs: [Int] = [], hiddenChannelIDs: [Int] = []) {
        self.favoriteChannelIDs = favoriteChannelIDs
        self.hiddenChannelIDs = hiddenChannelIDs
    }

    private enum CodingKeys: String, CodingKey {
        case favoriteChannelIDs
        case hiddenChannelIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favoriteChannelIDs = try container.decodeIfPresent([Int].self, forKey: .favoriteChannelIDs) ?? []
        hiddenChannelIDs = try container.decodeIfPresent([Int].self, forKey: .hiddenChannelIDs) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(favoriteChannelIDs, forKey: .favoriteChannelIDs)
        try container.encode(hiddenChannelIDs, forKey: .hiddenChannelIDs)
    }

    var normalized: ChannelSettings {
        var seenFavoriteIDs: Set<Int> = []
        var seenHiddenIDs: Set<Int> = []
        return ChannelSettings(
            favoriteChannelIDs: favoriteChannelIDs.filter { channelID in
                seenFavoriteIDs.insert(channelID).inserted
            },
            hiddenChannelIDs: hiddenChannelIDs.filter { channelID in
                seenHiddenIDs.insert(channelID).inserted
            }
        )
    }

    func orderedItems(_ items: [ChannelSelectionItem], includeHidden: Bool = false) -> [ChannelSelectionItem] {
        let sourceItems = includeHidden
            ? items
            : items.filter { !containsHidden($0.id) }
        var itemsByID: [Int: ChannelSelectionItem] = [:]
        for item in sourceItems where itemsByID[item.id] == nil {
            itemsByID[item.id] = item
        }

        let normalizedIDs = normalized.favoriteChannelIDs
        let favorites = normalizedIDs.compactMap { itemsByID[$0] }
        let favoriteSet = Set(normalizedIDs)
        let regularItems = sourceItems.filter { !favoriteSet.contains($0.id) }
        return favorites + regularItems
    }

    func containsFavorite(_ channelID: Int) -> Bool {
        favoriteChannelIDs.contains(channelID)
    }

    func containsHidden(_ channelID: Int) -> Bool {
        hiddenChannelIDs.contains(channelID)
    }

    mutating func setFavorite(_ isFavorite: Bool, channelID: Int) {
        if isFavorite {
            guard !favoriteChannelIDs.contains(channelID) else { return }
            favoriteChannelIDs.append(channelID)
        } else {
            favoriteChannelIDs.removeAll { $0 == channelID }
        }
        self = normalized
    }

    mutating func setHidden(_ isHidden: Bool, channelID: Int) {
        if isHidden {
            guard !hiddenChannelIDs.contains(channelID) else { return }
            hiddenChannelIDs.append(channelID)
        } else {
            hiddenChannelIDs.removeAll { $0 == channelID }
        }
        self = normalized
    }

    mutating func moveFavorite(channelID: Int, by offset: Int) {
        self = normalized
        guard let currentIndex = favoriteChannelIDs.firstIndex(of: channelID) else { return }
        let nextIndex = currentIndex + offset
        guard favoriteChannelIDs.indices.contains(nextIndex) else { return }
        favoriteChannelIDs.swapAt(currentIndex, nextIndex)
    }

    mutating func moveFavorite(channelID: Int, toDropTarget targetChannelID: Int) {
        self = normalized
        guard channelID != targetChannelID,
              let currentIndex = favoriteChannelIDs.firstIndex(of: channelID),
              let targetIndex = favoriteChannelIDs.firstIndex(of: targetChannelID)
        else { return }
        let value = favoriteChannelIDs.remove(at: currentIndex)
        favoriteChannelIDs.insert(value, at: targetIndex)
    }
}
