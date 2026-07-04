import Foundation

struct AppState: Codable, Equatable {
    static let currentVersion = 1

    var version: Int
    var tileLayout: TileLayoutConfig
    var settings: AppSettings
    var channelSettings: ChannelSettings
    var windowFrame: WindowFrameState?

    init(
        version: Int = AppState.currentVersion,
        tileLayout: TileLayoutConfig,
        settings: AppSettings = .empty,
        channelSettings: ChannelSettings = .empty,
        windowFrame: WindowFrameState? = nil
    ) {
        self.version = version
        self.tileLayout = tileLayout
        self.settings = settings
        self.channelSettings = channelSettings
        self.windowFrame = windowFrame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        guard decodedVersion >= 0, decodedVersion <= Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported app state version: \(decodedVersion)"
            )
        }
        version = Self.currentVersion
        tileLayout = try container.decode(TileLayoutConfig.self, forKey: .tileLayout)
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? .empty
        channelSettings = try container.decodeIfPresent(
            ChannelSettings.self,
            forKey: .channelSettings
        ) ?? .empty
        windowFrame = try container.decodeIfPresent(WindowFrameState.self, forKey: .windowFrame)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case tileLayout
        case settings
        case channelSettings
        case windowFrame
    }
}

struct WindowFrameState: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(rect: CGRect) {
        self.init(
            x: Double(rect.origin.x),
            y: Double(rect.origin.y),
            width: Double(rect.size.width),
            height: Double(rect.size.height)
        )
    }

    var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    var summary: String {
        "x=\(Int(x.rounded())) y=\(Int(y.rounded())) w=\(Int(width.rounded())) h=\(Int(height.rounded()))"
    }
}

struct AppStateStore {
    let url: URL

    static func `default`() throws -> AppStateStore {
        if let overridePath = ProcessInfo.processInfo.environment["REPLAYCENTER_STATE_PATH"] {
            return AppStateStore(url: URL(fileURLWithPath: overridePath))
        }

        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("ReplayCenter", isDirectory: true)
        return AppStateStore(url: directory.appendingPathComponent("app-state.json"))
    }

    func load() throws -> AppState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(AppState.self, from: data)
    }

    func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: url, options: .atomic)
    }
}
