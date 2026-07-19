import AppKit
import SwiftUI
import Speech
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var setupWindowController: NSWindowController?
    var overlayController: OverlayWindowController?
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestPermissions()
        setupMenuBar()
        NSApp.setActivationPolicy(.regular)
        Task { await ProviderHealth.shared.checkAll() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.showSetup()
        }
    }

    // MARK: - Menu bar icon (always visible so user can reopen setup)
    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "ShadowPilot")
            button.action = #selector(menuBarTapped)
            button.target = self
        }
    }

    @objc private func menuBarTapped() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Open Setup", action: #selector(reopenSetup), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ShadowPilot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openDashboard() {
        Task { @MainActor in DashboardWindow.show() }
    }

    @objc private func reopenSetup() {
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
