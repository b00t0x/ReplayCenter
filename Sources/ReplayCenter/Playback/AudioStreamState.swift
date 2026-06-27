import Foundation

enum AudioStreamState: String, Sendable {
    case unknown
    case stereoSingle
    case dualMono
    case multiStream

    var displayText: String {
        switch self {
        case .unknown:
            return "音声判定中"
        case .stereoSingle:
            return "単一音声"
        case .dualMono:
            return "デュアルモノ"
        case .multiStream:
            return "複数音声"
        }
    }

    var supportsCurrentAudioModeControls: Bool {
        self == .dualMono
    }
}
