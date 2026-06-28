import Foundation
import SwiftVLC

enum AudioMode: String, Decodable {
    case left
    case right

    var stereoMode: StereoMode {
        switch self {
        case .left:
            return .left
        case .right:
            return .right
        }
    }
}
