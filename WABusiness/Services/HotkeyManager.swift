import Carbon
import AppKit

// Global hotkeys without stealing focus from active app
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onMicToggle: (() -> Void)?       // ⌘⇧L  — start/stop listening
    var onGetAnswer: (() -> Void)?       // ⌘⇧A  — fire answer
    var onScreenshot: (() -> Void)?      // ⌘⇧D  — capture screen
    var onClear: (() -> Void)?           // ⌘⇧X  — clear
    var onWritingToggle: (() -> Void)?   // ⌘⇧W  — toggle typing mode
    var onBugScan: (() -> Void)?         // ⌘⇧B  — scan the loaded repo for bugs
    var onOpenSetup: (() -> Void)?       // ⌘⇧S  — reopen Setup (there is no menu bar icon)

    private var eventHandler: EventHandlerRef?
    private var hotkeys: [EventHotKeyRef?] = []

    private init() {}

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(GetApplicationEventTarget(),
                            { (_, event, userData) -> OSStatus in
                                guard let ud = userData else { return OSStatus(eventNotHandledErr) }
                                let me = Unmanaged<HotkeyManager>.fromOpaque(ud).takeUnretainedValue()
                                var hkID = EventHotKeyID()
                                GetEventParameter(event,
                                                  EventParamName(kEventParamDirectObject),
                                                  EventParamType(typeEventHotKeyID),
                                                  nil,
                                                  MemoryLayout<EventHotKeyID>.size,
                                                  nil,
                                                  &hkID)
                                DispatchQueue.main.async {
                                    switch hkID.id {
                                    case 1: me.onMicToggle?()
                                    case 2: me.onGetAnswer?()
                                    case 3: me.onScreenshot?()
                                    case 4: me.onClear?()
                                    case 5: me.onWritingToggle?()
                                    case 6: me.onBugScan?()
                                    case 7: me.onOpenSetup?()
                                    default: break
                                    }
                                }
                                return noErr
                            },
                            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)

        // ⌘⇧L
        registerKey(keyCode: UInt32(kVK_ANSI_L),
                    modifiers: UInt32(cmdKey | shiftKey), id: 1)
        // ⌘⇧A
        registerKey(keyCode: UInt32(kVK_ANSI_A),
                    modifiers: UInt32(cmdKey | shiftKey), id: 2)
        // ⌘⇧D  (screenshot)
        registerKey(keyCode: UInt32(kVK_ANSI_D),
                    modifiers: UInt32(cmdKey | shiftKey), id: 3)
        // ⌘⇧X  (clear)
        registerKey(keyCode: UInt32(kVK_ANSI_X),
                    modifiers: UInt32(cmdKey | shiftKey), id: 4)
        // ⌘⇧W  (writing toggle)
        registerKey(keyCode: UInt32(kVK_ANSI_W),
                    modifiers: UInt32(cmdKey | shiftKey), id: 5)
        // ⌘⇧B  (repo bug scan)
        registerKey(keyCode: UInt32(kVK_ANSI_B),
                    modifiers: UInt32(cmdKey | shiftKey), id: 6)
        // ⌘⇧S  (reopen Setup — the app has no menu bar or Dock icon)
        registerKey(keyCode: UInt32(kVK_ANSI_S),
                    modifiers: UInt32(cmdKey | shiftKey), id: 7)
    }

    private func registerKey(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        let hkID = EventHotKeyID(signature: OSType(0x5350), id: id)
        var ref: EventHotKeyRef?
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        hotkeys.append(ref)
    }
}
