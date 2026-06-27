import Foundation

enum AudioSelection: String, Sendable {
    case primary
    case secondary

    var displayText: String {
        switch self {
        case .primary:
            return "主"
        case .secondary:
            return "副"
        }
    }

    var filterAudioMode: AudioMode {
        switch self {
        case .primary:
            return .left
        case .secondary:
            return .right
        }
    }
}

extension AudioSelection {
    init(audioMode: AudioMode) {
        switch audioMode {
        case .right:
            self = .secondary
        case .stereo, .left:
            self = .primary
        }
    }
}
