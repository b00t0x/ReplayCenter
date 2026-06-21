import AppKit
import SwiftUI
import SwiftVLC

@MainActor
final class ReplayCenterAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let config: AppConfig
    private let configSource: String?
    private let instance: VLCInstance
    private var window: NSWindow?
    private var tileGrid: TileGridModel?
    private var channelCatalog: ChannelCatalogModel?
    private var activity: NSObjectProtocol?
    private var shuttingDown = false
    private var shutdownComplete = false
    private weak var terminationReplySender: NSApplication?

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
        installMainMenu()

        activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleSystemSleepDisabled,
                .suddenTerminationDisabled,
                .automaticTerminationDisabled
            ],
            reason: "ReplayCenter live playback"
        )

        let tileGrid = TileGridModel(config: config, instance: instance)
        self.tileGrid = tileGrid
        let channelCatalog = config.epgStationBaseURL.map { ChannelCatalogModel(client: EPGStationClient(baseURL: $0)) }
        self.channelCatalog = channelCatalog
        let view = ContentView(model: tileGrid, channelCatalog: channelCatalog)

        let window = NSWindow(
            contentRect: NSRect(x: 140, y: 140, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = config.windowTitle ?? "ReplayCenter"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !shutdownComplete else { return .terminateNow }
        beginShutdown(replyTo: sender)
        return .terminateLater
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        beginShutdown(replyTo: nil)
        return false
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        endActivityIfNeeded()
    }

    private func beginShutdown(replyTo sender: NSApplication?) {
        if let sender {
            terminationReplySender = sender
        }

        guard !shuttingDown else { return }
        shuttingDown = true
        window?.standardWindowButton(.closeButton)?.isEnabled = false

        Task { @MainActor in
            await tileGrid?.shutdown()
            tileGrid = nil
            channelCatalog = nil
            window?.contentView = nil
            shutdownComplete = true
            endActivityIfNeeded()

            if let terminationReplySender {
                terminationReplySender.reply(toApplicationShouldTerminate: true)
            } else {
                NSApp.terminate(nil)
            }
        }
    }

    private func endActivityIfNeeded() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "ReplayCenter を終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }
}
