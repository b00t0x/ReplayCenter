import AppKit
import Foundation

do {
    let loadedConfig = try ConfigLoader.load()
    let app = NSApplication.shared
    let delegate = try ReplayCenterAppDelegate(config: loadedConfig.config, configSource: loadedConfig.source)
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    app.run()
} catch {
    fputs("Failed to start ReplayCenter: \(error.localizedDescription)\n", stderr)
    exit(1)
}
