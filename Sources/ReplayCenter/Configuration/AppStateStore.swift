import Foundation

struct AppState: Codable, Equatable {
    var tileLayout: TileLayoutConfig
    var settings: AppSettings

    init(tileLayout: TileLayoutConfig, settings: AppSettings = .empty) {
        self.tileLayout = tileLayout
        self.settings = settings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tileLayout = try container.decode(TileLayoutConfig.self, forKey: .tileLayout)
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? .empty
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
