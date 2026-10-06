import AppKit
import Carbon
import UtsushieCore

@MainActor
final class GlobalHotkey {
    private var reference: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    private var registered: Hotkey?
    private let identifier: UInt32

    init(identifier: UInt32 = 1) {
        self.identifier = identifier
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotkey = Unmanaged<GlobalHotkey>.fromOpaque(context).takeUnretainedValue()
            var id = EventHotKeyID()
            guard let event, GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                id.signature == 0x55545355, id.id == hotkey.identifier else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { hotkey.onPress?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }
    func register(_ hotkey: Hotkey) -> String? {
        if registered == hotkey { return nil }
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil; registered = nil
        let id = EventHotKeyID(signature: 0x55545355, id: identifier)
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers, id, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { return "ホットキーを登録できません。他アプリとの重複を確認してください。OSStatus: \(status)" }
        registered = hotkey
        return nil
    }
    func stop() {
        unregister()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }
    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil; registered = nil
    }
}
