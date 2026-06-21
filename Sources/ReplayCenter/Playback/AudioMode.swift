import Foundation
import SwiftVLC

enum AudioMode: String, Decodable {
    case stereo
    case left
    case right

    var stereoMode: StereoMode {
        switch self {
        case .stereo:
            return .stereo
        case .left:
            return .left
        case .right:
            return .right
        }
    }
}
