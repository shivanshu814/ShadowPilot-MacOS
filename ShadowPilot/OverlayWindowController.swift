import AppKit
import SwiftUI

// NSPanel with nonactivatingPanel style — clicks here do NOT steal focus from other apps
class OverlayWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

class OverlayWindowController: NSWindowController {
    convenience init() {
        let window = OverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 52),
            styleMask: [.borderless, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.sharingType = .none
        // Prevent this window from appearing in app switcher / Mission Control focus changes
        window.hidesOnDeactivate = false

        let hostingView = NSHostingView(rootView: ContentView())
        window.contentView = hostingView

        self.init(window: window)

        if let screen = NSScreen.main {
            let x = (screen.frame.width - 700) / 2
            let y = screen.frame.height - 120
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        // Auto-resize height to content
        NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: hostingView,
            queue: .main
        ) { [weak window] _ in
            guard let window, let hosting = window.contentView else { return }
            let fit = hosting.fittingSize
            guard fit.height > 0 else { return }
            var frame = window.frame
            let delta = fit.height - frame.height
            frame.size.height = fit.height
            frame.origin.y -= delta
            window.setFrame(frame, display: true, animate: false)
        }
    }
}
