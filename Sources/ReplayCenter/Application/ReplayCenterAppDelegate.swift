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
    var titlebarHeight: CGFloat = 0
    var topOverlayChromeHeight: CGFloat = 0
}

@MainActor
final class ReplayCenterAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate, NSMenuItemValidation {
    private static let settingsMinimumContentSize = CGSize(width: 1040, height: 640)
    private static let channelSelectorMinimumContentSize = CGSize(width: 560, height: 600)
    private static let tileBasePixelSize = CGSize(width: 1920, height: 1080)
    private static let fullScreenMenuRevealBandHeight: CGFloat = 36
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
    private var overlayRemovedResizable = false
    private var lastMeasuredTitlebarHeight: CGFloat = 0
    private var lastWindowedFrame: WindowFrameState?
    private var windowHoverMonitorTokens: [Any] = []
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
            applyRestoredWindowFrame(windowFrame, to: window)
        } else {
            updateCachedWindowFrame(for: window)
        }
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
        self.window = window
        window.contentView = NSHostingView(rootView: view)
        installWindowHoverTracking(for: window)
        window.makeKeyAndOrderFront(nil)
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
    }

    private func updateWindowHoverState(for window: NSWindow?) {
        guard let window else { return }
        let mouseLocation = NSEvent.mouseLocation
        let isHovering = window.isVisible && window.frame.contains(mouseLocation)
        let isFullScreen = window.styleMask.contains(.fullScreen)

        if windowChrome.isHovering != isHovering {
            windowChrome.isHovering = isHovering
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(openSettings(_:)):
            return tileGrid != nil && tileGrid?.isSettingsPresented != true
        case #selector(setFixedWindowScale(_:)):
            menuItem.state = fixedWindowScaleState(for: menuItem)
            return canApplyFixedWindowScale
        case #selector(toggleFullScreen(_:)):
            menuItem.title = window?.styleMask.contains(.fullScreen) == true
                ? "フルスクリーンを解除"
                : "フルスクリーンにする"
            return window != nil && overlayBaseContentSize == nil
        case #selector(toggleStreamInfoOverlay(_:)):
            menuItem.state = (tileGrid?.settings.showStreamInfoOverlay ?? true) ? .on : .off
            return tileGrid != nil
        case #selector(toggleChannelProgramOverlayAlways(_:)):
            menuItem.state = (tileGrid?.settings.channelProgramOverlayVisibility ?? .always) == .always
                ? .on
                : .off
            return tileGrid != nil
        case #selector(toggleKeepFocusOnSingleLargeTile(_:)):
            menuItem.state = (tileGrid?.settings.keepFocusOnSingleLargeTile ?? true) ? .on : .off
            return tileGrid != nil
        default:
            return true
        }
    }

    @objc private func openSettings(_ sender: Any?) {
        tileGrid?.presentSettings()
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

    @objc private func toggleStreamInfoOverlay(_ sender: Any?) {
        guard let tileGrid else { return }
        let currentValue = tileGrid.settings.showStreamInfoOverlay ?? true
        tileGrid.setShowStreamInfoOverlay(!currentValue)
    }

    @objc private func toggleChannelProgramOverlayAlways(_ sender: Any?) {
        guard let tileGrid else { return }
        let currentValue = tileGrid.settings.channelProgramOverlayVisibility ?? .always
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
            disableWindowResizeDuringOverlay(window)
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
            restoreWindowResizeAfterOverlay(window)
            applyWindowLayout(tileGrid.layout, resize: false)
            guard !window.styleMask.contains(.fullScreen) else { return }
            if let restoreSize {
                window.setContentSize(contentSize(restoreSize, fitting: tileGrid.layout))
            } else {
                applyWindowLayout(tileGrid.layout, resize: true)
            }
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

    private var canApplyFixedWindowScale: Bool {
        guard let window else { return false }
        return tileGrid != nil
            && overlayBaseContentSize == nil
            && !window.styleMask.contains(.fullScreen)
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

    private func applyRestoredWindowFrame(_ windowFrame: WindowFrameState, to window: NSWindow) {
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
            constrainedWindowFrame(restoredFrame, on: screen),
            display: false,
            animate: false
        )
        updateCachedWindowFrame(for: window)
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
              !window.styleMask.contains(.fullScreen),
              overlayBaseContentSize == nil
        else {
            return lastWindowedFrame
        }
        let frame = WindowFrameState(rect: window.frame)
        lastWindowedFrame = frame
        return frame
    }

    private static func fixedWindowScale(percent: Int) -> FixedWindowScale? {
        fixedWindowScales.first { $0.percent == percent }
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
        updateCachedWindowFrame(for: window)
    }
}

private extension NSRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}
