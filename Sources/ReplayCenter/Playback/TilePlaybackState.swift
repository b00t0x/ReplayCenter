import Foundation

enum TilePlaybackState: Equatable {
    case idle
    case starting
    case playing
    case failed(String)

    var isFailure: Bool {
        if case .failed = self {
            return true
        }
        return false
    }

    var displayText: String? {
        switch self {
        case .idle:
            return nil
        case .starting:
            return "読み込み中"
        case .playing:
            return nil
        case .failed:
            return "再生失敗"
        }
    }
}
