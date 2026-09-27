import Carbon.HIToolbox
import Foundation

/// System-wide hotkey support (Carbon, so it works without extra permissions).
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var installed = false

    var onFire: (() -> Void)?
    private(set) var lastRegistrationFailed = false

    func register(presets: [Prefs.HotKeyPreset]) {
        unregister()
        installHandlerIfNeeded()
        for preset in presets {
            guard let keyCode = preset.keyCode else { continue }
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: OSType(0x4C50_4144), id: UInt32(references.count + 1))
            let status = RegisterEventHotKey(keyCode,
                                             preset.carbonModifiers,
                                             identifier,
                                             GetApplicationEventTarget(),
                                             0,
                                             &reference)
            if status == noErr, let reference {
                references.append(reference)
            } else {
                lastRegistrationFailed = true
                Log.error("hotkey \(preset.title) registration failed (\(status))")
            }
        }
    }

    func registerDefault() {
        var presets: [Prefs.HotKeyPreset] = [Prefs.hotKey]
        // Old Launchpad muscle memory is F4; register it as well when possible
        // and always keep a shortcut that cannot be taken by the system.
        for fallback in [Prefs.HotKeyPreset.f4, .controlCommandL, .optionCommandSpace] where !presets.contains(fallback) {
            presets.append(fallback)
        }
        register(presets: presets)
    }

    func unregister() {
        for reference in references { UnregisterEventHotKey(reference) }
        references.removeAll()
    }

    fileprivate func fire() { onFire?() }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(),
                                         launchpadHotKeyHandler,
                                         1,
                                         &eventType,
                                         nil,
                                         &handler)
        installed = status == noErr
    }
}

private func launchpadHotKeyHandler(_ nextHandler: EventHandlerCallRef?,
                                    _ event: EventRef?,
                                    _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated {
        GlobalHotKey.shared.fire()
    }
    return noErr
}
