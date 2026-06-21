import Foundation

struct LoadedConfig {
    var config: AppConfig
    var source: String?
}

enum ConfigLoader {
    static func load() throws -> LoadedConfig {
        let explicitPath = configPathFromArguments() ?? ProcessInfo.processInfo.environment["REPLAYCENTER_CONFIG"]

        if let explicitPath {
            return LoadedConfig(config: try loadFile(at: explicitPath), source: explicitPath)
        }

        let localPath = "config.local.json"
        if FileManager.default.fileExists(atPath: localPath) {
            return LoadedConfig(config: try loadFile(at: localPath), source: localPath)
        }

        return LoadedConfig(config: .empty, source: nil)
    }

    private static func configPathFromArguments() -> String? {
        let args = CommandLine.arguments
        if let configIndex = args.firstIndex(of: "--config"), args.indices.contains(configIndex + 1) {
            return args[configIndex + 1]
        }
        return nil
    }

    private static func loadFile(at path: String) throws -> AppConfig {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(AppConfig.self, from: data)
    }
}
