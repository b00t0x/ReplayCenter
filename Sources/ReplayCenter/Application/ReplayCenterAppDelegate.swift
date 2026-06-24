import AppKit
import SwiftUI
import SwiftVLC

@MainActor
final class ReplayCenterAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let settingsMinimumContentSize = CGSize(width: 860, height: 560)
    private static let channelSelectorMinimumContentSize = CGSize(width: 560, height: 600)
    private let config: AppConfig
    private let configSource: String?
    private let stateStore: AppStateStore
    private let restoredState: AppState?
    private let instance: VLCInstance
    private var window: NSWindow?
    private var tileGrid: TileGridModel?
    private var channelCatalog: ChannelCatalogModel?
    private var activity: NSObjectProtocol?
    private var shuttingDown = false
    private var shutdownComplete = false
    private var overlayBaseContentSize: CGSize?
    private weak var terminationReplySender: NSApplication?

    init(config: AppConfig, configSource: String?, stateStore: AppStateStore) throws {
        self.configSource = configSource
        self.stateStore = stateStore
        let restoredState = Self.loadSavedState(from: stateStore)
        self.restoredState = restoredState
        self.config = config.applying(restoredState?.settings)

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

        let tileGrid = TileGridModel(config: config, instance: instance, restoredState: restoredState)
        self.tileGrid = tileGrid
        let channelCatalog = config.epgStationBaseURL.map { ChannelCatalogModel(client: EPGStationClient(baseURL: $0)) }
        self.channelCatalog = channelCatalog
        let view = ContentView(
            model: tileGrid,
            channelCatalog: channelCatalog,
            onChannelSelectorPresentationChanged: { [weak self] isPresented in
                self?.applyOverlayWindowMode(
                    isPresented: isPresented,
                    minimumContentSize: Self.channelSelectorMinimumContentSize
                )
            }
        )

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 140, y: 140), size: tileGrid.layout.initialWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = config.windowTitle ?? "ReplayCenter"
        window.delegate = self
        window.isReleasedWhenClosed = false
        applyWindowLayout(tileGrid.layout, to: window, resize: false)
        tileGrid.onLayoutChanged = { [weak self] layout in
            if self?.tileGrid?.isSettingsPresented != true {
                self?.applyWindowLayout(layout, resize: true)
            }
            self?.saveCurrentState(fallbackLayout: layout)
        }
        tileGrid.onSettingsChanged = { [weak self] _ in
            self?.saveCurrentState()
        }
        tileGrid.onSettingsPresentationChanged = { [weak self] isPresented in
            self?.applyOverlayWindowMode(
                isPresented: isPresented,
                minimumContentSize: Self.settingsMinimumContentSize
            )
        }
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
        saveCurrentState()
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
        let settingsItem = NSMenuItem(
            title: "設定...",
            action: #selector(openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "ReplayCenter を終了",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openSettings(_ sender: Any?) {
        tileGrid?.presentSettings()
    }

    private static func loadSavedState(from stateStore: AppStateStore) -> AppState? {
        do {
            let state = try stateStore.load()
            if let state {
                fputs(
                    "[app] state source=\(stateStore.url.path) tileLayout=\(state.tileLayout.summary) settings=\(state.settings.summary)\n",
                    stderr
                )
            } else {
                fputs("[app] state source=\(stateStore.url.path) <empty>\n", stderr)
            }
            return state
        } catch {
            fputs("[app] state load failed source=\(stateStore.url.path) error=\(error)\n", stderr)
            return nil
        }
    }

    private func saveCurrentState(fallbackLayout: TileLayoutConfig? = nil) {
        guard let tileGrid else { return }
        saveState(
            layout: fallbackLayout ?? tileGrid.layout,
            settings: tileGrid.settings,
            channelSettings: tileGrid.channelSettings
        )
    }

    private func saveState(
        layout: TileLayoutConfig,
        settings: AppSettings,
        channelSettings: ChannelSettings
    ) {
        do {
            try stateStore.save(
                AppState(
                    tileLayout: layout,
                    settings: settings,
                    channelSettings: channelSettings
                )
            )
        } catch {
            fputs("[app] state save failed target=\(stateStore.url.path) error=\(error)\n", stderr)
        }
    }

    private func applyWindowLayout(_ layout: TileLayoutConfig, resize: Bool) {
        guard let window else { return }
        applyWindowLayout(layout, to: window, resize: resize)
    }

    private func applyOverlayWindowMode(isPresented: Bool, minimumContentSize: CGSize) {
        guard let window, let tileGrid else { return }
        if isPresented {
            if overlayBaseContentSize == nil {
                overlayBaseContentSize = window.contentLayoutRect.size
            }
            window.contentAspectRatio = .zero
            window.contentMinSize = minimumContentSize
            guard !window.styleMask.contains(.fullScreen) else { return }

            let currentSize = window.contentLayoutRect.size
            let targetSize = CGSize(
                width: max(currentSize.width, minimumContentSize.width),
                height: max(currentSize.height, minimumContentSize.height)
            )
            if targetSize != currentSize {
                window.setContentSize(targetSize)
            }
        } else {
            let restoreSize = overlayBaseContentSize
            overlayBaseContentSize = nil
            applyWindowLayout(tileGrid.layout, resize: false)
            guard !window.styleMask.contains(.fullScreen) else { return }
            if let restoreSize {
                window.setContentSize(contentSize(restoreSize, fitting: tileGrid.layout))
            } else {
                applyWindowLayout(tileGrid.layout, resize: true)
            }
        }
    }

    private func contentSize(_ sourceSize: CGSize, fitting layout: TileLayoutConfig) -> CGSize {
        let aspect = layout.gridAspectRatio.width / layout.gridAspectRatio.height
        let minimumSize = layout.minimumWindowSize
        let width = max(sourceSize.width, minimumSize.width)
        let height = max(width / aspect, minimumSize.height)
        return CGSize(width: max(height * aspect, minimumSize.width), height: height)
    }

    private func applyWindowLayout(_ layout: TileLayoutConfig, to window: NSWindow, resize: Bool) {
        window.contentAspectRatio = layout.gridAspectRatio
        window.contentMinSize = layout.minimumWindowSize
        guard resize, !window.styleMask.contains(.fullScreen) else { return }

        let currentSize = window.contentLayoutRect.size
        let aspect = layout.gridAspectRatio.width / layout.gridAspectRatio.height
        let targetWidth = max(currentSize.width, layout.minimumWindowSize.width)
        let targetHeight = max(targetWidth / aspect, layout.minimumWindowSize.height)
        window.setContentSize(CGSize(width: targetWidth, height: targetHeight))
    }
}
