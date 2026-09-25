#if DEBUG
import AppKit
import SwiftUI

/// Writes PNGs of the relay's menu bar panel and dashboard panes, for README and
/// App Store screenshots. Debug builds only; see `DemoMode`.
@MainActor
enum DemoSnapshots {
    static func write(to folder: String) async {
        let directory = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Opens the demo store and seeds it before any view reads it.
        _ = DataStore.shared
        RelayEngine.shared.applyDemoState()

        await capture(
            MenuBarContent(),
            title: nil,
            size: NSSize(width: 320, height: 300),
            to: directory.appendingPathComponent("mac-menu-bar.png")
        )
        for pane in [DashboardView.Pane.setup, .activity] {
            await capture(
                DashboardView(initialPane: pane).modelContainer(DataStore.shared.container),
                title: "BlueNudge Relay",
                size: NSSize(width: 900, height: 640),
                to: directory.appendingPathComponent("mac-\(pane.rawValue.lowercased()).png")
            )
        }
    }

    private static func capture<Content: View>(_ view: Content, title: String?, size: NSSize, to file: URL) async {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = title == nil ? [.borderless] : [.titled, .closable, .miniaturizable]
        window.title = title ?? ""
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        // Let SwiftUI lay out, load data and draw.
        try? await Task.sleep(nanoseconds: 2_500_000_000)

        if let image = image(of: window), let png = image.representation(using: .png, properties: [:]) {
            try? png.write(to: file)
        }
        window.orderOut(nil)
    }

    /// The window as the user sees it. Capturing this app's own window needs no
    /// Screen Recording permission; `cacheDisplay` is the fallback.
    private static func image(of window: NSWindow) -> NSBitmapImageRep? {
        if let cgImage = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .bestResolution]
        ) {
            return NSBitmapImageRep(cgImage: cgImage)
        }
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
#endif
