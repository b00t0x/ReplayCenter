import Foundation

struct ChannelSettings: Codable, Equatable {
    var favoriteChannelIDs: [Int]

    static let empty = ChannelSettings(favoriteChannelIDs: [])

    var normalized: ChannelSettings {
        var seen: Set<Int> = []
        return ChannelSettings(
            favoriteChannelIDs: favoriteChannelIDs.filter { channelID in
                seen.insert(channelID).inserted
            }
        )
    }

    func orderedItems(_ items: [ChannelSelectionItem]) -> [ChannelSelectionItem] {
        var itemsByID: [Int: ChannelSelectionItem] = [:]
        for item in items where itemsByID[item.id] == nil {
            itemsByID[item.id] = item
        }

        let normalizedIDs = normalized.favoriteChannelIDs
        let favorites = normalizedIDs.compactMap { itemsByID[$0] }
        let favoriteSet = Set(normalizedIDs)
        let regularItems = items.filter { !favoriteSet.contains($0.id) }
        return favorites + regularItems
    }

    func containsFavorite(_ channelID: Int) -> Bool {
        favoriteChannelIDs.contains(channelID)
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

    mutating func moveFavorite(channelID: Int, by offset: Int) {
        self = normalized
        guard let currentIndex = favoriteChannelIDs.firstIndex(of: channelID) else { return }
        let nextIndex = currentIndex + offset
        guard favoriteChannelIDs.indices.contains(nextIndex) else { return }
        favoriteChannelIDs.swapAt(currentIndex, nextIndex)
    }
}
