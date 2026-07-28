import AppKit
import SwiftUI
import Speech
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var setupWindowController: NSWindowController?
    var overlayController: OverlayWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestPermissions()
        // No menu bar icon and no Dock icon once the overlay is up: nothing about
        // this app should be visible on screen. Cmd+Shift+S is the way back to
        // Setup, which is also where Quit lives.
        HotkeyManager.shared.onOpenSetup = { [weak self] in self?.reopenSetup() }
        NSApp.setActivationPolicy(.regular)
        Task { await ProviderHealth.shared.checkAll() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.showSetup()
        }
    }

    @objc private func openDashboard() {
        Task { @MainActor in DashboardWindow.show() }
    }

    @objc private func reopenSetup() {
        // Already open: just bring it forward instead of building a second one.
        if let existing = setupWindowController?.window {
            NSApp.setActivationPolicy(.regular)
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        overlayController?.window?.close()
        overlayController = nil
        NSApp.setActivationPolicy(.regular)
        showSetup()
    }

    // MARK: - Setup window
    func showSetup() {
        let width: CGFloat  = 460
        let height: CGFloat = 720

        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: width, height: height)
        panel.maxSize = NSSize(width: width, height: height)

        let view = SetupView(isSetupDone: Binding(
            get: { false },
            set: { [weak self] done in
                guard done else { return }
                self?.setupWindowController?.window?.orderOut(nil)
                self?.setupWindowController = nil
                self?.launchOverlay()
            }
        ))

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        panel.contentView = hosting
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)

        setupWindowController = NSWindowController(window: panel)
    }

    // MARK: - Overlay pill
    func launchOverlay() {
        NSApp.setActivationPolicy(.accessory)
        // Menu bar icon stays — it's the way back to Dashboard/Setup
        overlayController = OverlayWindowController()
        overlayController?.showWindow(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            (self.overlayController?.window as? OverlayWindow)?.focusTextField()
        }
    }

    private func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
