import AppKit
import SwiftUI

class TextFieldRef {
    static let shared = TextFieldRef()
    weak var field: NSTextField?
}

// NSPanel with nonactivatingPanel style — clicks here do NOT steal focus from other apps
class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func focusTextField() {
        NSLog("[SP] focusTextField called")
        NSLog("[SP] activationPolicy before: %d", NSApp.activationPolicy().rawValue)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        NSLog("[SP] isKeyWindow after makeKey: %d", self.isKeyWindow ? 1 : 0)
        NSLog("[SP] canBecomeKey: %d", self.canBecomeKey ? 1 : 0)
        NSLog("[SP] TextFieldRef.field nil: %d", TextFieldRef.shared.field == nil ? 1 : 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            NSLog("[SP] 100ms — isKeyWindow: %d", self.isKeyWindow ? 1 : 0)
            if let field = TextFieldRef.shared.field {
                NSLog("[SP] field found, has window: %d", field.window != nil ? 1 : 0)
                let result = self.makeFirstResponder(field)
                NSLog("[SP] makeFirstResponder result: %d", result ? 1 : 0)
                NSLog("[SP] firstResponder class: %@", self.firstResponder?.className ?? "nil")
            } else {
                NSLog("[SP] ERROR: TextFieldRef.field is nil!")
            }
        }
    }

    func unfocusTextField() {
        resignKey()
        NSApp.setActivationPolicy(.accessory)
    }
}

// Subclass so every click fires immediately without needing app activation first
class AcceptsFirstMouseHostingView<R: View>: NSHostingView<R> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class OverlayWindowController: NSWindowController {
    convenience init() {
        let window = OverlayWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 52),
            styleMask: [.borderless, .fullSizeContentView],
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

        let hostingView = AcceptsFirstMouseHostingView(rootView: ContentView())
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
