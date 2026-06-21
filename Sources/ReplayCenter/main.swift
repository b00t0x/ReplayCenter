import AppKit
import Foundation
import SwiftUI
import SwiftVLC

struct AppConfig: Decodable {
    var windowTitle: String?
    var vlcArguments: [String]?
    var networkCachingMs: Int?
    var deinterlace: String?
    var mediaOptions: [String]?
    var audioOnlyFocusedTile: Bool?
    var startMuted: Bool?
    var audioMode: AudioMode?
    var streams: [StreamConfig]

    static let empty = AppConfig(
        windowTitle: "ReplayCenter",
        vlcArguments: [],
        networkCachingMs: 1000,
        deinterlace: "yadif",
        mediaOptions: [],
        audioOnlyFocusedTile: true,
        startMuted: true,
        audioMode: .stereo,
        streams: []
    )

    var effectiveDeinterlaceLabel: String {
        let value = deinterlace?.trimmingCharacters(in: .whitespacesAndNewlines)
        return value?.isEmpty == false ? value! : "<unchanged>"
    }

    var summary: String {
        [
            "streams=\(streams.count)",
            "deinterlace=\(effectiveDeinterlaceLabel)",
            "networkCachingMs=\(networkCachingMs.map(String.init) ?? "<nil>")",
            "audioOnlyFocusedTile=\(audioOnlyFocusedTile.map(String.init) ?? "<nil>")",
            "startMuted=\(startMuted.map(String.init) ?? "<nil>")",
            "audioMode=\(audioMode?.rawValue ?? "<nil>")",
            "vlcArguments=\(vlcArguments ?? [])",
            "mediaOptions=\(mediaOptions ?? [])"
        ].joined(separator: " ")
    }
}

struct StreamConfig: Decodable, Identifiable {
    var id: String { title ?? url }
    var title: String?
    var url: String
    var muted: Bool?
    var audioMode: AudioMode?
    var deinterlace: String?
    var mediaOptions: [String]?
}

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

@MainActor
@Observable
final class TileModel: Identifiable {
    let id = UUID()
    let stream: StreamConfig
    let player: Player
    private let config: AppConfig
    private var started = false
    private var currentAudioMode: AudioMode

    init(stream: StreamConfig, config: AppConfig, instance: VLCInstance) {
        self.stream = stream
        self.config = config
        self.player = Player(instance: instance)
        currentAudioMode = stream.audioMode ?? config.audioMode ?? .stereo
        player.isMuted = stream.muted ?? config.startMuted ?? true
        player.stereoMode = currentAudioMode.stereoMode
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        start()
    }

    func setMuted(_ muted: Bool) {
        player.isMuted = muted
    }

    func setAudioMode(_ mode: AudioMode) {
        currentAudioMode = mode
        player.stereoMode = mode.stereoMode
    }

    func shutdown() async {
        await player.shutdown()
    }

    private func start() {
        guard let url = URL(string: stream.url) else {
            log("invalid url=\(stream.url)")
            return
        }

        do {
            let media = try Media(url: url)
            if let networkCachingMs = config.networkCachingMs {
                media.addOption(":network-caching=\(networkCachingMs)")
                media.addOption(":live-caching=\(networkCachingMs)")
            }
            for option in config.mediaOptions ?? [] {
                media.addOption(option)
            }
            for option in stream.mediaOptions ?? [] {
                media.addOption(option)
            }

            applyDeinterlaceIfNeeded()
            try player.play(media)
            log("play url=\(stream.url) deinterlace=\(effectiveDeinterlaceLabel)")
        } catch {
            log("play failed error=\(error)")
        }
    }

    private func applyDeinterlaceIfNeeded() {
        let deinterlace = effectiveDeinterlaceLabel
        guard deinterlace != "<unchanged>" else { return }

        do {
            switch deinterlace.lowercased() {
            case "off", "none", "false", "disabled", "disable":
                try player.setDeinterlace(state: 0)
            case "auto":
                try player.setDeinterlace(state: -1)
            default:
                try player.setDeinterlace(state: 1, mode: deinterlace)
            }
        } catch {
            log("deinterlace failed mode=\(deinterlace) error=\(error)")
        }
    }

    private var effectiveDeinterlaceLabel: String {
        let streamValue = stream.deinterlace?.trimmingCharacters(in: .whitespacesAndNewlines)
        if streamValue?.isEmpty == false {
            return streamValue!
        }
        return config.effectiveDeinterlaceLabel
    }

    private func log(_ message: String) {
        fputs("[\(stream.title ?? stream.url)] \(message)\n", stderr)
    }
}

struct TileView: View {
    @Bindable var model: TileModel
    let focused: Bool
    let onFocus: () -> Void

    var body: some View {
        VideoView(model.player)
            .background(Color.black)
            .overlay(alignment: .topLeading) {
                Text(model.stream.title ?? model.stream.url)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.58))
                    .foregroundStyle(.white)
            }
            .overlay {
                Rectangle()
                    .stroke(focused ? Color.accentColor : Color.clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onFocus()
            }
            .task {
                model.startIfNeeded()
            }
    }
}

struct ContentView: View {
    @State private var focusedIndex = 0
    let models: [TileModel]
    let audioOnlyFocusedTile: Bool

    var body: some View {
        Group {
            if models.isEmpty {
                ZStack {
                    Color.black
                    Text("ストリーム未設定")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            } else {
                tileGrid
            }
        }
        .background(Color.black)
        .focusable()
        .onKeyPress { keyPress in
            handleKeyPress(keyPress.characters.lowercased())
        }
        .onAppear {
            if !models.isEmpty {
                focus(0)
            }
        }
    }

    private var tileGrid: some View {
        GeometryReader { proxy in
            let columns = Int(ceil(sqrt(Double(models.count))))
            let rows = Int(ceil(Double(models.count) / Double(columns)))
            let cellWidth = proxy.size.width / CGFloat(columns)
            let cellHeight = proxy.size.height / CGFloat(rows)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: 0), count: columns),
                spacing: 0
            ) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    TileView(model: model, focused: focusedIndex == index) {
                        focus(index)
                    }
                    .frame(width: cellWidth, height: cellHeight)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func handleKeyPress(_ characters: String) -> KeyPress.Result {
        guard models.indices.contains(focusedIndex) else { return .ignored }

        switch characters {
        case "s":
            models[focusedIndex].setAudioMode(.stereo)
            return .handled
        case "l":
            models[focusedIndex].setAudioMode(.left)
            return .handled
        case "r":
            models[focusedIndex].setAudioMode(.right)
            return .handled
        default:
            return .ignored
        }
    }

    private func focus(_ index: Int) {
        guard models.indices.contains(index) else { return }
        focusedIndex = index
        guard audioOnlyFocusedTile else { return }

        for (modelIndex, model) in models.enumerated() {
            model.setMuted(modelIndex != index)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: AppConfig
    private let configSource: String?
    private let instance: VLCInstance
    private var window: NSWindow?
    private var models: [TileModel] = []
    private var activity: NSObjectProtocol?
    private var shuttingDown = false

    init(config: AppConfig, configSource: String?) throws {
        self.config = config
        self.configSource = configSource

        var arguments = VLCInstance.defaultArguments + [
            "--no-osd",
            "--quiet"
        ]
        arguments.append(contentsOf: config.vlcArguments ?? [])
        if let networkCachingMs = config.networkCachingMs {
            arguments.append("--network-caching=\(networkCachingMs)")
        }

        instance = try VLCInstance(arguments: arguments)
        fputs("[app] config source=\(configSource ?? "<default>") \(config.summary)\n", stderr)
        fputs("[app] libvlc arguments=\(arguments)\n", stderr)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleSystemSleepDisabled,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled
            ],
            reason: "ReplayCenter live playback"
        )

        models = config.streams.map { TileModel(stream: $0, config: config, instance: instance) }
        let view = ContentView(
            models: models,
            audioOnlyFocusedTile: config.audioOnlyFocusedTile ?? true
        )

        let window = NSWindow(
            contentRect: NSRect(x: 140, y: 140, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = config.windowTitle ?? "ReplayCenter"
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shuttingDown else { return .terminateNow }
        shuttingDown = true
        window?.orderOut(nil)

        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for model in models {
                    group.addTask { await model.shutdown() }
                }
            }
            models.removeAll()
            endActivityIfNeeded()
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        endActivityIfNeeded()
    }

    private func endActivityIfNeeded() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

do {
    let loadedConfig = try ConfigLoader.load()
    let app = NSApplication.shared
    let delegate = try AppDelegate(config: loadedConfig.config, configSource: loadedConfig.source)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
} catch {
    fputs("Failed to start ReplayCenter: \(error.localizedDescription)\n", stderr)
    exit(1)
}
