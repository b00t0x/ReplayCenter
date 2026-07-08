import AppKit
import SwiftUI
import SwiftVLC

private struct FixedWindowScale {
    let percent: Int
    let value: CGFloat
}

@Observable
final class WindowChromeModel {
    var isHovering = false
    var areHoverInteractionsActive = false
    var forceFocusedTileHover = false
    var titlebarHeight: CGFloat = 0
    var topOverlayChromeHeight: CGFloat = 0
}

@MainActor
final class ReplayCenterAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private static let settingsMinimumContentSize = CGSize(width: 1000, height: 640)
    private static let channelSelectorMinimumContentSize = CGSize(width: 560, height: 600)
    private static let tileLayoutPickerMinimumContentSize = CGSize(width: 960, height: 620)
    private static let tileBasePixelSize = CGSize(width: 1920, height: 1080)
    private static let fullScreenMenuRevealBandHeight: CGFloat = 36
    private static let mouseInactivityDelay: Duration = .seconds(3)
    private static let fixedWindowScales = [
        FixedWindowScale(percent: 50, value: 0.5),
        FixedWindowScale(percent: 66, value: 2.0 / 3.0),
        FixedWindowScale(percent: 75, value: 0.75),
        FixedWindowScale(percent: 100, value: 1.0),
        FixedWindowScale(percent: 150, value: 1.5),
        FixedWindowScale(percent: 200, value: 2.0)
    ]
    private static let fixedWindowScaleTagBase = 10_000
    private let config: AppConfig
    private let configSource: String?
    private let stateStore: AppStateStore
    private let restoredState: AppState?
    private let instance: VLCInstance
    private let windowChrome = WindowChromeModel()
    private var window: NSWindow?
    private var tileGrid: TileGridModel?
    private var activity: NSObjectProtocol?
    private var shuttingDown = false
    private var shutdownComplete = false
    private var overlayBaseContentSize: CGSize?
    private var overlayBaseLayout: TileLayoutConfig?
    private var overlayRemovedResizable = false
    private var lastMeasuredTitlebarHeight: CGFloat = 0
    private var lastWindowedFrame: WindowFrameState?
    private var windowHoverMonitorTokens: [Any] = []
    private var mouseInactivityTask: Task<Void, Never>?
    private var contentWindowDragStartOrigin: NSPoint?
    private var contentWindowDragStartMouseLocation: NSPoint?
    private weak var windowSizeMenu: NSMenu?
    private weak var terminationReplySender: NSApplication?

    init(config: AppConfig, configSource: String?, stateStore: AppStateStore) throws {
        self.configSource = configSource
        self.stateStore = stateStore
        let savedState = Self.loadSavedState(from: stateStore)
        let restoredState = configSource == nil ? savedState : nil
        self.restoredState = restoredState
        self.lastWindowedFrame = restoredState?.windowFrame
        let effectiveConfig = config.applying(restoredState?.settings)
        self.config = effectiveConfig

        var arguments = VLCInstance.defaultArguments + [
            "--no-osd",
            "--quiet"
        ]
        arguments.append(contentsOf: effectiveConfig.vlcArguments ?? [])
        if let networkCachingMs = effectiveConfig.networkCachingMs {
            arguments.append("--network-caching=\(networkCachingMs)")
        }

        instance = try VLCInstance(arguments: arguments)
        fputs("[app] config source=\(configSource ?? "<default>") \(effectiveConfig.summary)\n", stderr)
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
        let view = ContentView(
            model: tileGrid,
            windowChrome: windowChrome,
            onChannelSelectorPresentationChanged: { [weak self] isPresented in
                self?.applyOverlayWindowMode(
                    isPresented: isPresented,
                    minimumContentSize: Self.channelSelectorMinimumContentSize
                )
            },
            onTileLayoutPickerPresentationChanged: { [weak self] isPresented in
                self?.applyOverlayWindowMode(
                    isPresented: isPresented,
                    minimumContentSize: Self.tileLayoutPickerMinimumContentSize
                )
            },
            onFullScreenExitRequested: { [weak self] in
                self?.exitFullScreenIfNeeded() ?? false
            },
            onRevealHoverInteractions: { [weak self] in
                self?.revealHoverInteractions()
            },
            onContentWindowDragChanged: { [weak self] in
                self?.moveWindowForContentDrag()
            },
            onContentWindowDragEnded: { [weak self] in
                self?.finishContentWindowDrag()
            }
        )

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: 140, y: 140), size: tileGrid.layout.initialWindowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = tileGrid.focusedWindowTitle
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        configureTitlebarExperiment(for: window)
        tileGrid.onFocusedTitleChanged = { [weak self] title in
            self?.window?.title = title
        }
        applyWindowLayout(tileGrid.layout, to: window, resize: false)
        if let windowFrame = restoredState?.windowFrame {
            applyRestoredWindowFrame(windowFrame, fitting: tileGrid.layout, to: window)
        } else {
            updateCachedWindowFrame(for: window)
        }
        tileGrid.onLayoutChanged = { [weak self] oldLayout, layout in
            if self?.overlayBaseContentSize == nil,
               self?.tileGrid?.isSettingsPresented != true
            {
                self?.applyWindowLayout(layout, resize: true, preservingTileSizeFrom: oldLayout)
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
        self.window = window
        window.contentView = NSHostingView(rootView: view)
        installWindowHoverTracking(for: window)
        window.makeKeyAndOrderFront(nil)
        Task { [weak self] in
            await self?.presentSettingsIfEPGStationUnavailable()
        }
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
        removeWindowHoverTracking()
        contentWindowDragStartOrigin = nil
        contentWindowDragStartMouseLocation = nil
        window = nil
    }

    func windowDidResize(_ notification: Notification) {
        updateTitlebarMetrics(for: notification.object as? NSWindow)
        updateCachedWindowFrame(for: notification.object as? NSWindow)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveCurrentState()
    }

    func windowDidMove(_ notification: Notification) {
        updateCachedWindowFrame(for: notification.object as? NSWindow)
        guard contentWindowDragStartOrigin == nil else { return }
        saveCurrentState()
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        updateCachedWindowFrame(for: notification.object as? NSWindow, allowDuringFullScreenTransition: true)
        saveCurrentState()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        updateTitlebarMetrics(for: notification.object as? NSWindow)
        updateWindowHoverState(for: notification.object as? NSWindow)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        updateTitlebarMetrics(for: notification.object as? NSWindow)
        updateWindowHoverState(for: notification.object as? NSWindow)
        updateCachedWindowFrame(for: notification.object as? NSWindow)
        saveCurrentState()
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
        removeWindowHoverTracking()
        saveCurrentState()
        window?.standardWindowButton(.closeButton)?.isEnabled = false

        Task { @MainActor in
            await tileGrid?.shutdown()
            tileGrid = nil
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

    private func presentSettingsIfEPGStationUnavailable() async {
        guard configSource == nil, let tileGrid else { return }
        guard !(await canConnectToEPGStation(baseURL: config.epgStationBaseURL)) else { return }
        fputs("[app] EPGStation setup required\n", stderr)
        tileGrid.presentSettings(requiresEPGStationConnection: true)
    }

    private func canConnectToEPGStation(baseURL: URL?) async -> Bool {
        guard let baseURL else { return false }
        do {
            _ = try await EPGStationClient(baseURL: baseURL).fetchConfig()
            return true
        } catch {
            fputs("[app] EPGStation config probe failed error=\(error)\n", stderr)
            return false
        }
    }

    private func moveWindowForContentDrag() {
        guard let window,
              overlayBaseContentSize == nil,
              tileGrid?.isSettingsPresented != true,
              !window.styleMask.contains(.fullScreen)
        else {
            return
        }

        let currentMouseLocation = NSEvent.mouseLocation
        if contentWindowDragStartOrigin == nil {
            contentWindowDragStartOrigin = window.frame.origin
            contentWindowDragStartMouseLocation = currentMouseLocation
        }

        guard let startOrigin = contentWindowDragStartOrigin,
              let startMouseLocation = contentWindowDragStartMouseLocation
        else {
            return
        }

        window.setFrameOrigin(NSPoint(
            x: startOrigin.x + currentMouseLocation.x - startMouseLocation.x,
            y: startOrigin.y + currentMouseLocation.y - startMouseLocation.y
        ))
    }

    private func finishContentWindowDrag() {
        guard contentWindowDragStartOrigin != nil else { return }
        contentWindowDragStartOrigin = nil
        contentWindowDragStartMouseLocation = nil
        updateCachedWindowFrame(for: window)
        saveCurrentState()
    }

    private func configureTitlebarExperiment(for window: NSWindow) {
        updateTitlebarMetrics(for: window)
        setTitlebarVisible(false, in: window)
    }

    private func setTitlebarVisible(_ isVisible: Bool, in window: NSWindow?) {
        guard let window else { return }
        window.titleVisibility = isVisible ? .visible : .hidden
        window.titlebarAppearsTransparent = !isVisible
        for buttonType in [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton
        ] {
            window.standardWindowButton(buttonType)?.isHidden = !isVisible
        }
        updateTitlebarMetrics(for: window)
        Task { @MainActor in
            updateTitlebarMetrics(for: window)
        }
    }

    private func updateTitlebarMetrics(for window: NSWindow?) {
        guard let window else { return }
        let measuredTitlebarHeight = max(window.frame.height - window.contentLayoutRect.height, 0)
        if measuredTitlebarHeight > 0.5 {
            lastMeasuredTitlebarHeight = measuredTitlebarHeight
        }
        let titlebarHeight = measuredTitlebarHeight > 0.5
            ? measuredTitlebarHeight
            : 0
        if abs(windowChrome.titlebarHeight - titlebarHeight) > 0.5 {
            windowChrome.titlebarHeight = titlebarHeight
        }
    }

    private func installWindowHoverTracking(for window: NSWindow) {
        removeWindowHoverTracking()
        let masks: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged
        ]

        if let localMonitor = NSEvent.addLocalMonitorForEvents(matching: masks, handler: { [weak self, weak window] event in
            Task { @MainActor in
                self?.updateWindowHoverState(for: window)
            }
            return event
        }) {
            windowHoverMonitorTokens.append(localMonitor)
        }

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: masks, handler: { [weak self, weak window] _ in
            Task { @MainActor in
                self?.updateWindowHoverState(for: window)
            }
        }) {
            windowHoverMonitorTokens.append(globalMonitor)
        }
    }

    private func removeWindowHoverTracking() {
        for token in windowHoverMonitorTokens {
            NSEvent.removeMonitor(token)
        }
        windowHoverMonitorTokens.removeAll()
        mouseInactivityTask?.cancel()
        mouseInactivityTask = nil
    }

    private func updateWindowHoverState(for window: NSWindow?) {
        guard let window else { return }
        let mouseLocation = NSEvent.mouseLocation
        let isHovering = window.isVisible && window.frame.contains(mouseLocation)
        let isFullScreen = window.styleMask.contains(.fullScreen)
        let shouldAutoHide = shouldAutoHideHoverInteractions

        if windowChrome.forceFocusedTileHover {
            windowChrome.forceFocusedTileHover = false
        }
        if windowChrome.isHovering != isHovering {
            windowChrome.isHovering = isHovering
        }
        if windowChrome.areHoverInteractionsActive != isHovering {
            windowChrome.areHoverInteractionsActive = isHovering
        }

        mouseInactivityTask?.cancel()
        mouseInactivityTask = nil
        if isHovering && shouldAutoHide {
            scheduleMouseInactivityTimeout(for: window)
        }

        if !isFullScreen {
            setTitlebarVisible(isHovering, in: window)
        } else {
            updateTitlebarMetrics(for: window)
        }

        let topOverlayChromeHeight = topOverlayChromeHeight(
            for: window,
            mouseLocation: mouseLocation,
            isHovering: isHovering,
            isFullScreen: isFullScreen
        )
        if abs(windowChrome.topOverlayChromeHeight - topOverlayChromeHeight) > 0.5 {
            windowChrome.topOverlayChromeHeight = topOverlayChromeHeight
        }
    }

    private func revealHoverInteractions() {
        guard let window, window.isVisible else { return }
        let isFullScreen = window.styleMask.contains(.fullScreen)
        let mouseLocation = NSEvent.mouseLocation

        windowChrome.forceFocusedTileHover = true
        windowChrome.isHovering = true
        windowChrome.areHoverInteractionsActive = true

        mouseInactivityTask?.cancel()
        mouseInactivityTask = nil
        if shouldAutoHideHoverInteractions {
            scheduleMouseInactivityTimeout(for: window)
        }

        if !isFullScreen {
            setTitlebarVisible(true, in: window)
        } else {
            updateTitlebarMetrics(for: window)
        }

        let topOverlayChromeHeight = topOverlayChromeHeight(
            for: window,
            mouseLocation: mouseLocation,
            isHovering: true,
            isFullScreen: isFullScreen
        )
        if abs(windowChrome.topOverlayChromeHeight - topOverlayChromeHeight) > 0.5 {
            windowChrome.topOverlayChromeHeight = topOverlayChromeHeight
        }
    }

    private var shouldAutoHideHoverInteractions: Bool {
        overlayBaseContentSize == nil && tileGrid?.isSettingsPresented != true
    }

    private func scheduleMouseInactivityTimeout(for window: NSWindow) {
        mouseInactivityTask = Task { [weak self, weak window] in
            do {
                try await Task.sleep(for: Self.mouseInactivityDelay)
            } catch {
                return
            }
            await MainActor.run {
                self?.hideHoverInteractionsIfIdle(for: window)
            }
        }
    }

    private func hideHoverInteractionsIfIdle(for window: NSWindow?) {
        guard shouldAutoHideHoverInteractions, let window, window.isVisible else { return }
        guard NSEvent.pressedMouseButtons == 0 else {
            scheduleMouseInactivityTimeout(for: window)
            return
        }
        let mouseLocation = NSEvent.mouseLocation
        let isHovering = window.frame.contains(mouseLocation)
        guard isHovering else {
            windowChrome.areHoverInteractionsActive = false
            windowChrome.isHovering = false
            windowChrome.forceFocusedTileHover = false
            windowChrome.topOverlayChromeHeight = 0
            setTitlebarVisible(false, in: window)
            return
        }

        windowChrome.areHoverInteractionsActive = false
        windowChrome.isHovering = false
        windowChrome.forceFocusedTileHover = false
        if !window.styleMask.contains(.fullScreen) {
            setTitlebarVisible(false, in: window)
        } else {
            updateTitlebarMetrics(for: window)
        }
        if abs(windowChrome.topOverlayChromeHeight) > 0.5 {
            windowChrome.topOverlayChromeHeight = 0
        }
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    private func topOverlayChromeHeight(
        for window: NSWindow,
        mouseLocation: NSPoint,
        isHovering: Bool,
        isFullScreen: Bool
    ) -> CGFloat {
        if isFullScreen {
            guard isMouseInFullScreenMenuRevealBand(mouseLocation, window: window) else { return 0 }
            return max(lastMeasuredTitlebarHeight, 28) + NSStatusBar.system.thickness
        }
        return isHovering ? windowChrome.titlebarHeight : 0
    }

    private func isMouseInFullScreenMenuRevealBand(_ mouseLocation: NSPoint, window: NSWindow) -> Bool {
        guard let screen = window.screen else { return false }
        return screen.frame.maxY - mouseLocation.y <= Self.fullScreenMenuRevealBandHeight
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let aboutItem = NSMenuItem(
            title: "ReplayCenter について",
            action: #selector(showAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(.separator())

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

        installEditMenu(in: mainMenu)

        let viewMenuItem = NSMenuItem(title: "表示", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)

        let viewMenu = NSMenu(title: "表示")
        let windowSizeItem = NSMenuItem(title: "ウィンドウサイズ", action: nil, keyEquivalent: "")
        let windowSizeMenu = NSMenu(title: "ウィンドウサイズ")
        windowSizeMenu.delegate = self
        self.windowSizeMenu = windowSizeMenu
        for (index, scale) in Self.fixedWindowScales.enumerated() {
            let item = NSMenuItem(
                title: "\(scale.percent)%",
                action: #selector(setFixedWindowScale(_:)),
                keyEquivalent: "\(index + 1)"
            )
            item.keyEquivalentModifierMask = [.command, .option]
            item.tag = Self.fixedWindowScaleTagBase + scale.percent
            item.target = self
            windowSizeMenu.addItem(item)
        }
        windowSizeItem.submenu = windowSizeMenu
        viewMenu.addItem(windowSizeItem)

        viewMenu.addItem(.separator())
        let tileLayoutItem = NSMenuItem(
            title: "タイル配置...",
            action: #selector(openTileLayoutPicker(_:)),
            keyEquivalent: "t"
        )
        tileLayoutItem.keyEquivalentModifierMask = []
        tileLayoutItem.target = self
        viewMenu.addItem(tileLayoutItem)

        viewMenu.addItem(.separator())
        let fullScreenItem = NSMenuItem(
            title: "フルスクリーンにする",
            action: #selector(toggleFullScreen(_:)),
            keyEquivalent: "f"
        )
        fullScreenItem.keyEquivalentModifierMask = [.command, .control]
        fullScreenItem.target = self
        viewMenu.addItem(fullScreenItem)

        viewMenu.addItem(.separator())
        let streamInfoItem = NSMenuItem(
            title: "ストリーム情報を表示",
            action: #selector(toggleStreamInfoOverlay(_:)),
            keyEquivalent: ""
        )
        streamInfoItem.target = self
        viewMenu.addItem(streamInfoItem)

        let channelProgramInfoItem = NSMenuItem(
            title: "チャンネル/番組情報を常時表示",
            action: #selector(toggleChannelProgramOverlayAlways(_:)),
            keyEquivalent: ""
        )
        channelProgramInfoItem.target = self
        viewMenu.addItem(channelProgramInfoItem)

        let keepFocusOnLargeTileItem = NSMenuItem(
            title: "フォーカス時にラージタイルへ入れ替え",
            action: #selector(toggleKeepFocusOnSingleLargeTile(_:)),
            keyEquivalent: ""
        )
        keepFocusOnLargeTileItem.target = self
        viewMenu.addItem(keepFocusOnLargeTileItem)
        viewMenuItem.submenu = viewMenu

        installPlaybackMenu(in: mainMenu)

        NSApp.mainMenu = mainMenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === windowSizeMenu else { return }
        updateFixedWindowScaleMenuStates()
    }

    private func installEditMenu(in mainMenu: NSMenu) {
        let editMenuItem = NSMenuItem(title: "編集", action: nil, keyEquivalent: "")
        mainMenu.addItem(editMenuItem)

        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(NSMenuItem(title: "取り消す", action: Selector(("undo:")), keyEquivalent: "z"))

        let redoItem = NSMenuItem(title: "やり直す", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())

        editMenu.addItem(NSMenuItem(title: "カット", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "ペースト", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "削除", action: #selector(NSText.delete(_:)), keyEquivalent: ""))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        editMenuItem.submenu = editMenu
    }

    private func installPlaybackMenu(in mainMenu: NSMenu) {
        let playbackMenuItem = NSMenuItem(title: "再生", action: nil, keyEquivalent: "")
        mainMenu.addItem(playbackMenuItem)

        let playbackMenu = NSMenu(title: "再生")

        let channelSelectionItem = NSMenuItem(
            title: "選局...",
            action: #selector(openFocusedChannelSelector(_:)),
            keyEquivalent: "c"
        )
        channelSelectionItem.keyEquivalentModifierMask = []
        channelSelectionItem.target = self
        playbackMenu.addItem(channelSelectionItem)

        playbackMenu.addItem(.separator())

        let primaryAudioItem = NSMenuItem(
            title: "主音声",
            action: #selector(selectPrimaryAudio(_:)),
            keyEquivalent: ""
        )
        primaryAudioItem.target = self
        playbackMenu.addItem(primaryAudioItem)

        let secondaryAudioItem = NSMenuItem(
            title: "副音声",
            action: #selector(selectSecondaryAudio(_:)),
            keyEquivalent: ""
        )
        secondaryAudioItem.target = self
        playbackMenu.addItem(secondaryAudioItem)

        playbackMenu.addItem(.separator())

        let muteItem = NSMenuItem(
            title: "ミュート",
            action: #selector(toggleFocusedTileMuted(_:)),
            keyEquivalent: "m"
        )
        muteItem.keyEquivalentModifierMask = []
        muteItem.target = self
        playbackMenu.addItem(muteItem)

        let decreaseVolumeItem = NSMenuItem(
            title: "音量を下げる",
            action: #selector(decreaseFocusedTileVolume(_:)),
            keyEquivalent: "["
        )
        decreaseVolumeItem.keyEquivalentModifierMask = []
        decreaseVolumeItem.target = self
        playbackMenu.addItem(decreaseVolumeItem)

        let increaseVolumeItem = NSMenuItem(
            title: "音量を上げる",
            action: #selector(increaseFocusedTileVolume(_:)),
            keyEquivalent: "]"
        )
        increaseVolumeItem.keyEquivalentModifierMask = []
        increaseVolumeItem.target = self
        playbackMenu.addItem(increaseVolumeItem)

        playbackMenu.addItem(.separator())

        let reloadItem = NSMenuItem(
            title: "再読み込み",
            action: #selector(reloadFocusedTile(_:)),
            keyEquivalent: ""
        )
        reloadItem.target = self
        playbackMenu.addItem(reloadItem)

        let clearTileItem = NSMenuItem(
            title: "タイルをクリア",
            action: #selector(clearFocusedTile(_:)),
            keyEquivalent: "\u{7f}"
        )
        clearTileItem.keyEquivalentModifierMask = []
        clearTileItem.target = self
        playbackMenu.addItem(clearTileItem)

        playbackMenuItem.submenu = playbackMenu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showAboutPanel(_:)):
            return true
        case #selector(openSettings(_:)):
            return tileGrid != nil && tileGrid?.isSettingsPresented != true
        case #selector(setFixedWindowScale(_:)):
            menuItem.state = fixedWindowScaleState(for: menuItem)
            return canApplyFixedWindowScale
        case #selector(openTileLayoutPicker(_:)):
            return canOpenTileLayoutPicker
        case #selector(toggleFullScreen(_:)):
            menuItem.title = window?.styleMask.contains(.fullScreen) == true
                ? "フルスクリーンを解除"
                : "フルスクリーンにする"
            return window != nil && overlayBaseContentSize == nil
        case #selector(toggleStreamInfoOverlay(_:)):
            menuItem.state = (tileGrid?.settings.showStreamInfoOverlay ?? false) ? .on : .off
            return tileGrid != nil
        case #selector(toggleChannelProgramOverlayAlways(_:)):
            menuItem.state = (tileGrid?.settings.channelProgramOverlayVisibility ?? .onHover) == .always
                ? .on
                : .off
            return tileGrid != nil
        case #selector(toggleKeepFocusOnSingleLargeTile(_:)):
            menuItem.state = (tileGrid?.settings.keepFocusOnSingleLargeTile ?? true) ? .on : .off
            return tileGrid != nil
        case #selector(openFocusedChannelSelector(_:)):
            return canOpenFocusedChannelSelector
        case #selector(selectPrimaryAudio(_:)):
            menuItem.state = tileGrid?.focusedTileAudioSelection == .primary ? .on : .off
            return canUseFocusedAudioSelectionCommand
        case #selector(selectSecondaryAudio(_:)):
            menuItem.state = tileGrid?.focusedTileAudioSelection == .secondary ? .on : .off
            return canUseFocusedAudioSelectionCommand
        case #selector(toggleFocusedTileMuted(_:)):
            menuItem.state = tileGrid?.focusedTileIsMuted == true ? .on : .off
            return canUseFocusedTilePlaybackCommand
        case #selector(decreaseFocusedTileVolume(_:)):
            return canUseFocusedTilePlaybackCommand
                && (tileGrid?.focusedTileVolumePercent ?? VolumeLevel.minimum) > VolumeLevel.minimum
        case #selector(increaseFocusedTileVolume(_:)):
            return canUseFocusedTilePlaybackCommand
                && (tileGrid?.focusedTileVolumePercent ?? VolumeLevel.maximum) < VolumeLevel.maximum
        case #selector(reloadFocusedTile(_:)):
            return canUseFocusedTilePlaybackCommand
        case #selector(clearFocusedTile(_:)):
            return canUseFocusedTilePlaybackCommand
        default:
            return true
        }
    }

    @objc private func showAboutPanel(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "ReplayCenter",
            .applicationIcon: aboutPanelIcon,
            .applicationVersion: appDisplayVersion,
            .version: appDisplayVersion
        ])
    }

    @objc private func openSettings(_ sender: Any?) {
        tileGrid?.presentSettings()
    }

    @objc private func openFocusedChannelSelector(_ sender: Any?) {
        tileGrid?.requestFocusedChannelSelection()
    }

    @objc private func openTileLayoutPicker(_ sender: Any?) {
        tileGrid?.requestTileLayoutPicker()
    }

    @objc private func selectPrimaryAudio(_ sender: Any?) {
        tileGrid?.setFocusedAudioSelection(.primary)
    }

    @objc private func selectSecondaryAudio(_ sender: Any?) {
        tileGrid?.setFocusedAudioSelection(.secondary)
    }

    @objc private func toggleFocusedTileMuted(_ sender: Any?) {
        tileGrid?.toggleFocusedTileMuted()
    }

    @objc private func decreaseFocusedTileVolume(_ sender: Any?) {
        tileGrid?.decreaseVolume(stoppingAtRepeatBoundary: NSApp.currentEvent?.isARepeat == true)
        revealHoverInteractions()
    }

    @objc private func increaseFocusedTileVolume(_ sender: Any?) {
        tileGrid?.increaseVolume(stoppingAtRepeatBoundary: NSApp.currentEvent?.isARepeat == true)
        revealHoverInteractions()
    }

    @objc private func reloadFocusedTile(_ sender: Any?) {
        tileGrid?.reloadFocusedTile()
    }

    @objc private func clearFocusedTile(_ sender: Any?) {
        tileGrid?.clearFocusedTile()
    }

    @objc private func setFixedWindowScale(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        let scalePercent = item.tag - Self.fixedWindowScaleTagBase
        guard let scale = Self.fixedWindowScale(percent: scalePercent) else { return }
        applyFixedWindowScale(scale.value)
    }

    @objc private func toggleFullScreen(_ sender: Any?) {
        window?.toggleFullScreen(sender)
    }

    private func exitFullScreenIfNeeded() -> Bool {
        guard let window,
              overlayBaseContentSize == nil,
              window.styleMask.contains(.fullScreen)
        else {
            return false
        }
        window.toggleFullScreen(nil)
        return true
    }

    @objc private func toggleStreamInfoOverlay(_ sender: Any?) {
        guard let tileGrid else { return }
        let currentValue = tileGrid.settings.showStreamInfoOverlay ?? false
        tileGrid.setShowStreamInfoOverlay(!currentValue)
    }

    @objc private func toggleChannelProgramOverlayAlways(_ sender: Any?) {
        guard let tileGrid else { return }
        let currentValue = tileGrid.settings.channelProgramOverlayVisibility ?? .onHover
        tileGrid.setChannelProgramOverlayVisibility(currentValue == .onHover ? .always : .onHover)
    }

    @objc private func toggleKeepFocusOnSingleLargeTile(_ sender: Any?) {
        guard let tileGrid else { return }
        let currentValue = tileGrid.settings.keepFocusOnSingleLargeTile ?? true
        tileGrid.setKeepFocusOnSingleLargeTile(!currentValue)
    }

    private static func loadSavedState(from stateStore: AppStateStore) -> AppState? {
        do {
            let state = try stateStore.load()
            if let state {
                fputs(
                    "[app] state source=\(stateStore.url.path) tileLayout=\(state.tileLayout.summary) settings=\(state.settings.summary) windowFrame=\(state.windowFrame?.summary ?? "<nil>")\n",
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
            channelSettings: tileGrid.channelSettings,
            windowFrame: currentWindowFrameForSaving()
        )
    }

    private func saveState(
        layout: TileLayoutConfig,
        settings: AppSettings,
        channelSettings: ChannelSettings,
        windowFrame: WindowFrameState?
    ) {
        do {
            try stateStore.save(
                AppState(
                    tileLayout: layout,
                    settings: settings,
                    channelSettings: channelSettings,
                    windowFrame: windowFrame
                )
            )
        } catch {
            fputs("[app] state save failed target=\(stateStore.url.path) error=\(error)\n", stderr)
        }
    }

    private func applyWindowLayout(
        _ layout: TileLayoutConfig,
        resize: Bool,
        preservingTileSizeFrom previousLayout: TileLayoutConfig? = nil
    ) {
        guard let window else { return }
        applyWindowLayout(
            layout,
            to: window,
            resize: resize,
            preservingTileSizeFrom: previousLayout
        )
    }

    private func applyOverlayWindowMode(isPresented: Bool, minimumContentSize: CGSize) {
        guard let window, let tileGrid else { return }
        if isPresented {
            mouseInactivityTask?.cancel()
            mouseInactivityTask = nil
            if overlayBaseContentSize == nil {
                overlayBaseContentSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
                overlayBaseLayout = tileGrid.layout
            }
            disableWindowResizeDuringOverlay(window)
            window.contentAspectRatio = .zero
            window.contentMinSize = minimumContentSize
            guard !window.styleMask.contains(.fullScreen) else { return }

            let currentSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
            let targetSize = CGSize(
                width: max(currentSize.width, minimumContentSize.width),
                height: max(currentSize.height, minimumContentSize.height)
            )
            if targetSize != currentSize {
                window.setContentSize(targetSize)
            }
        } else {
            let restoreSize = overlayBaseContentSize
            let restoreLayout = overlayBaseLayout
            overlayBaseContentSize = nil
            overlayBaseLayout = nil
            restoreWindowResizeAfterOverlay(window)
            applyWindowLayout(tileGrid.layout, resize: false)
            updateWindowHoverState(for: window)
            guard !window.styleMask.contains(.fullScreen) else { return }
            if let restoreSize {
                let targetContentSize: CGSize
                if let restoreLayout {
                    targetContentSize = contentSize(
                        restoreSize,
                        preservingTileSizeFrom: restoreLayout,
                        fitting: tileGrid.layout,
                        in: window
                    )
                } else {
                    targetContentSize = contentSize(restoreSize, fitting: tileGrid.layout)
                }
                setContentSizePreservingTopLeft(targetContentSize, for: window)
            } else {
                applyWindowLayout(tileGrid.layout, resize: true)
            }
            updateWindowHoverState(for: window)
        }
    }

    private func disableWindowResizeDuringOverlay(_ window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen),
              window.styleMask.contains(.resizable)
        else {
            return
        }
        window.styleMask.remove(.resizable)
        overlayRemovedResizable = true
    }

    private func restoreWindowResizeAfterOverlay(_ window: NSWindow) {
        guard overlayRemovedResizable else { return }
        window.styleMask.insert(.resizable)
        overlayRemovedResizable = false
    }

    private func contentSize(_ sourceSize: CGSize, fitting layout: TileLayoutConfig) -> CGSize {
        let aspect = layout.gridAspectRatio.width / layout.gridAspectRatio.height
        let minimumSize = layout.minimumWindowSize
        let width = max(sourceSize.width, minimumSize.width)
        let height = max(width / aspect, minimumSize.height)
        return CGSize(width: max(height * aspect, minimumSize.width), height: height)
    }

    private func contentSize(
        _ sourceSize: CGSize,
        preservingTileSizeFrom sourceLayout: TileLayoutConfig,
        fitting targetLayout: TileLayoutConfig,
        in window: NSWindow
    ) -> CGSize {
        let cellScale = min(
            sourceSize.width / CGFloat(sourceLayout.columns * 16),
            sourceSize.height / CGFloat(sourceLayout.rows * 9)
        )
        guard cellScale.isFinite, cellScale > 0 else {
            return contentSize(sourceSize, fitting: targetLayout)
        }

        let minimumSize = targetLayout.minimumWindowSize
        var targetSize = CGSize(
            width: max(CGFloat(targetLayout.columns * 16) * cellScale, minimumSize.width),
            height: max(CGFloat(targetLayout.rows * 9) * cellScale, minimumSize.height)
        )

        guard let screen = window.screen ?? NSScreen.main else { return targetSize }
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetSize)
        ).size
        let visibleSize = screen.visibleFrame.size
        let shrinkScale = min(
            visibleSize.width / targetFrameSize.width,
            visibleSize.height / targetFrameSize.height,
            1
        )
        if shrinkScale.isFinite, shrinkScale > 0, shrinkScale < 1 {
            targetSize = CGSize(
                width: max(targetSize.width * shrinkScale, minimumSize.width),
                height: max(targetSize.height * shrinkScale, minimumSize.height)
            )
        }
        return targetSize
    }

    private var canApplyFixedWindowScale: Bool {
        guard let window else { return false }
        return tileGrid != nil
            && overlayBaseContentSize == nil
            && !window.styleMask.contains(.fullScreen)
    }

    private var canUseFocusedTilePlaybackCommand: Bool {
        guard let tileGrid else { return false }
        return overlayBaseContentSize == nil
            && !tileGrid.isSettingsPresented
            && tileGrid.focusedTileHasStream
    }

    private var canUseFocusedAudioSelectionCommand: Bool {
        canUseFocusedTilePlaybackCommand
            && tileGrid?.focusedTileSupportsAudioSelection == true
    }

    private var canOpenFocusedChannelSelector: Bool {
        guard let tileGrid else { return false }
        return overlayBaseContentSize == nil
            && !tileGrid.isSettingsPresented
    }

    private var canOpenTileLayoutPicker: Bool {
        canOpenFocusedChannelSelector
    }

    private var appDisplayVersion: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           !version.isEmpty
        {
            return version
        }
        if let version = developmentVersionFileValue {
            return version
        }
        return "Development"
    }

    private var developmentVersionFileValue: String? {
        let sourceURL = URL(fileURLWithPath: #filePath)
        let candidates = [
            sourceURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("VERSION"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("VERSION")
        ]

        for url in candidates {
            if let value = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty
            {
                return value
            }
        }
        return nil
    }

    private var aboutPanelIcon: NSImage {
        if let icon = NSImage(named: NSImage.applicationIconName) {
            return icon
        }
        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent("AppIcon.icns"),
           let icon = NSImage(contentsOf: resourceURL)
        {
            return icon
        }
        return NSApp.applicationIconImage
    }

    private func applyFixedWindowScale(_ scale: CGFloat) {
        guard canApplyFixedWindowScale, let window, let tileGrid else { return }
        let targetContentSize = fixedWindowContentSize(
            layout: tileGrid.layout,
            scale: scale,
            window: window
        )
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: targetContentSize)
        ).size
        let currentFrame = window.frame
        let anchoredFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )
        let screen = window.screen ?? NSScreen.main
        window.setFrame(
            constrainedWindowFrame(anchoredFrame, on: screen),
            display: true,
            animate: false
        )
        updateCachedWindowFrame(for: window)
        updateFixedWindowScaleMenuStates()
        saveCurrentState()
    }

    private func fixedWindowScaleState(for menuItem: NSMenuItem) -> NSControl.StateValue {
        guard let window, let tileGrid else { return .off }
        let scalePercent = menuItem.tag - Self.fixedWindowScaleTagBase
        guard let scale = Self.fixedWindowScale(percent: scalePercent) else { return .off }
        let currentSize = window.contentView?.bounds.size ?? window.contentLayoutRect.size
        let expectedSize = fixedWindowContentSize(
            layout: tileGrid.layout,
            scale: scale.value,
            window: window
        )
        let tolerance: CGFloat = 1
        return abs(currentSize.width - expectedSize.width) <= tolerance
            && abs(currentSize.height - expectedSize.height) <= tolerance ? .on : .off
    }

    private func updateFixedWindowScaleMenuStates() {
        guard let windowSizeMenu else { return }
        for item in windowSizeMenu.items {
            guard item.action == #selector(setFixedWindowScale(_:)) else { continue }
            item.state = fixedWindowScaleState(for: item)
            item.isEnabled = canApplyFixedWindowScale
        }
    }

    private func fixedWindowContentSize(
        layout: TileLayoutConfig,
        scale: CGFloat,
        window: NSWindow
    ) -> CGSize {
        let backingScale = max(window.screen?.backingScaleFactor ?? window.backingScaleFactor, 1)
        return CGSize(
            width: CGFloat(layout.columns) * Self.tileBasePixelSize.width * scale / backingScale,
            height: CGFloat(layout.rows) * Self.tileBasePixelSize.height * scale / backingScale
        )
    }

    private func constrainedWindowFrame(_ frame: NSRect, on screen: NSScreen?) -> NSRect {
        guard let screen else { return frame }
        let visibleFrame = screen.visibleFrame
        var constrained = frame

        if constrained.width <= visibleFrame.width {
            if constrained.maxX > visibleFrame.maxX {
                constrained.origin.x -= constrained.maxX - visibleFrame.maxX
            }
            if constrained.minX < visibleFrame.minX {
                constrained.origin.x += visibleFrame.minX - constrained.minX
            }
        } else {
            constrained.origin.x = visibleFrame.minX
        }

        if constrained.height <= visibleFrame.height {
            if constrained.minY < visibleFrame.minY {
                constrained.origin.y += visibleFrame.minY - constrained.minY
            }
            if constrained.maxY > visibleFrame.maxY {
                constrained.origin.y -= constrained.maxY - visibleFrame.maxY
            }
        } else {
            constrained.origin.y = visibleFrame.minY
        }

        return constrained
    }

    private func setContentSizePreservingTopLeft(_ contentSize: CGSize, for window: NSWindow) {
        let targetFrameSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: contentSize)
        ).size
        let currentFrame = window.frame
        let targetFrame = NSRect(
            x: currentFrame.minX,
            y: currentFrame.maxY - targetFrameSize.height,
            width: targetFrameSize.width,
            height: targetFrameSize.height
        )
        let screen = screen(for: targetFrame) ?? window.screen ?? NSScreen.main
        window.setFrame(
            constrainedWindowFrame(targetFrame, on: screen),
            display: true,
            animate: false
        )
    }

    private func applyRestoredWindowFrame(
        _ windowFrame: WindowFrameState,
        fitting layout: TileLayoutConfig,
        to window: NSWindow
    ) {
        let restoredFrame = NSRect(
            x: windowFrame.x,
            y: windowFrame.y,
            width: windowFrame.width,
            height: windowFrame.height
        )
        guard restoredFrame.width > 0, restoredFrame.height > 0 else {
            updateCachedWindowFrame(for: window)
            return
        }
        let screen = screen(for: restoredFrame) ?? window.screen ?? NSScreen.main
        window.setFrame(
            constrainedWindowFrame(
                adjustedWindowFrame(restoredFrame, fitting: layout, for: window),
                on: screen
            ),
            display: false,
            animate: false
        )
        updateCachedWindowFrame(for: window)
    }

    private func adjustedWindowFrame(
        _ sourceFrame: NSRect,
        preservingTileSizeFrom sourceLayout: TileLayoutConfig? = nil,
        fitting layout: TileLayoutConfig,
        for window: NSWindow
    ) -> NSRect {
        let sourceContentRect = window.contentRect(forFrameRect: sourceFrame)
        let adjustedContentSize: CGSize
        if let sourceLayout {
            adjustedContentSize = contentSize(
                sourceContentRect.size,
                preservingTileSizeFrom: sourceLayout,
                fitting: layout,
                in: window
            )
        } else {
            adjustedContentSize = contentSize(sourceContentRect.size, fitting: layout)
        }
        let adjustedContentRect = NSRect(origin: sourceContentRect.origin, size: adjustedContentSize)
        var adjustedFrame = window.frameRect(forContentRect: adjustedContentRect)
        adjustedFrame.origin.x = sourceFrame.origin.x
        adjustedFrame.origin.y = sourceFrame.maxY - adjustedFrame.height
        return adjustedFrame
    }

    private func screen(for frame: NSRect) -> NSScreen? {
        let center = NSPoint(x: frame.midX, y: frame.midY)
        if let containingScreen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return containingScreen
        }
        return NSScreen.screens.max { lhs, rhs in
            lhs.frame.intersection(frame).area < rhs.frame.intersection(frame).area
        }
    }

    private func updateCachedWindowFrame(
        for window: NSWindow?,
        allowDuringFullScreenTransition: Bool = false
    ) {
        guard let window else { return }
        guard overlayBaseContentSize == nil else { return }
        guard allowDuringFullScreenTransition || !window.styleMask.contains(.fullScreen) else { return }
        lastWindowedFrame = WindowFrameState(rect: window.frame)
    }

    private func currentWindowFrameForSaving() -> WindowFrameState? {
        guard let window,
              overlayBaseContentSize == nil
        else {
            return lastWindowedFrame
        }
        if window.styleMask.contains(.fullScreen) {
            guard let lastWindowedFrame, let tileGrid else { return lastWindowedFrame }
            let adjustedFrame = adjustedWindowFrame(lastWindowedFrame.rect, fitting: tileGrid.layout, for: window)
            let frame = WindowFrameState(rect: adjustedFrame)
            self.lastWindowedFrame = frame
            return frame
        }
        let frame = WindowFrameState(rect: window.frame)
        lastWindowedFrame = frame
        return frame
    }

    private static func fixedWindowScale(percent: Int) -> FixedWindowScale? {
        fixedWindowScales.first { $0.percent == percent }
    }

    private func applyWindowLayout(
        _ layout: TileLayoutConfig,
        to window: NSWindow,
        resize: Bool,
        preservingTileSizeFrom previousLayout: TileLayoutConfig? = nil
    ) {
        let sourceFrame = window.frame
        window.contentAspectRatio = layout.gridAspectRatio
        window.contentMinSize = layout.minimumWindowSize
        guard resize else { return }

        if window.styleMask.contains(.fullScreen) {
            if let previousLayout, let lastWindowedFrame {
                self.lastWindowedFrame = WindowFrameState(rect: adjustedWindowFrame(
                    lastWindowedFrame.rect,
                    preservingTileSizeFrom: previousLayout,
                    fitting: layout,
                    for: window
                ))
            }
            return
        }

        let targetFrame: NSRect
        if let previousLayout {
            targetFrame = adjustedWindowFrame(
                sourceFrame,
                preservingTileSizeFrom: previousLayout,
                fitting: layout,
                for: window
            )
        } else {
            targetFrame = adjustedWindowFrame(sourceFrame, fitting: layout, for: window)
        }
        window.setFrame(
            constrainedWindowFrame(targetFrame, on: window.screen ?? NSScreen.main),
            display: true,
            animate: false
        )
        updateCachedWindowFrame(for: window)
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
