import Carbon.HIToolbox

/// Global ctrl-opt-P via Carbon. Needs no Accessibility permission.
final class HotKey {
    private static var action: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func register(_ action: @escaping () -> Void) {
        HotKey.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            HotKey.action?()
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4F50_4950), id: 1) // 'OPIP'
        RegisterEventHotKey(UInt32(kVK_ANSI_P), UInt32(controlKey | optionKey), id,
                            GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
