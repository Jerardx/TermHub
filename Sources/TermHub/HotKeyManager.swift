import AppKit
import Carbon.HIToolbox

/// Registers a single system-wide hot key using the Carbon Hot Key API.
/// This does not require Accessibility/Input-Monitoring permissions (unlike
/// `NSEvent` global monitors), so it works out of the box.
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onPress: (() -> Void)?

    private init() {}

    /// Default: ⌘⌥T toggles the app's visibility.
    func registerDefault(onPress: @escaping () -> Void) {
        register(keyCode: UInt32(kVK_ANSI_T),
                 modifiers: UInt32(cmdKey | optionKey),
                 onPress: onPress)
    }

    func register(keyCode: UInt32, modifiers: UInt32, onPress: @escaping () -> Void) {
        self.onPress = onPress

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKeyManager.shared.onPress?()
            return noErr
        }, 1, &eventType, nil, &eventHandler)

        let id = EventHotKeyID(signature: OSType(0x54484B59), id: 1) // 'THKY'
        RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
