import AppKit
import Carbon
import ApplicationServices

final class KeyboardController {
    var onBrightness: ((Double) -> Void)?
    var onVolume: ((Double) -> Void)?
    var onMute: (() -> Void)?
    var onToggle: (() -> Void)?
    var canHandleMediaKey: ((Feature) -> Bool)?
    var onKeyboardAction: ((String) -> Void)?
    private var references: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private(set) var accessibilityTrusted = false
    private(set) var mediaKeyStatus = "disabled"
    var mediaKeyMessage: String {
        switch mediaKeyStatus {
        case "active": return L("键盘亮度键和音量键已启用。F10 静音，F11 减小音量，F12 增加音量。")
        case "permission-required": return L("光控尚未获得辅助功能权限。如果系统设置中已打开，请将其关闭后再打开，然后点按“前往设置”重新连接。")
        case "tap-failed": return L("已获得辅助功能权限，但键盘亮度键和音量键监听未能启动。请重新连接；如仍失败，请退出并重新打开光控。")
        default: return L("已停用键盘亮度键和音量键。⌃⌥ 组合快捷键仍可使用。")
        }
    }
    var diagnostics: [String: Any] {
        ["accessibilityTrusted": accessibilityTrusted, "mediaKeyStatus": mediaKeyStatus,
         "eventTapEnabled": eventTap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false,
         "registeredHotkeyCount": references.count, "appPath": Bundle.main.bundlePath]
    }
    private let signature: OSType = 0x4d4c4954

    func register() -> String? {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &key) == noErr else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<KeyboardController>.fromOpaque(context).takeUnretainedValue()
            guard key.signature == controller.signature else { return OSStatus(eventNotHandledErr) }
            controller.handle(key.id)
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { return L("无法注册全局快捷键，请重新打开光控。") }
        let mods = UInt32(controlKey | optionKey)
        let keys: [(UInt32, UInt32, UInt32)] = [
            (1, 126, mods), (2, 125, mods),
            (3, 126, mods | UInt32(shiftKey)), (4, 125, mods | UInt32(shiftKey)),
            (5, 124, mods), (6, 123, mods), (7, 46, mods), (8, 11, mods)
        ]
        var failed = false
        for (id, key, modifiers) in keys {
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(key, modifiers, EventHotKeyID(signature: signature, id: id),
                                            GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference { references.append(reference) } else { failed = true }
        }
        return failed ? L("部分快捷键已被其他应用占用。请停用冲突的快捷键，然后重新打开光控。") : nil
    }
    private func handle(_ id: UInt32) {
        onKeyboardAction?("shortcut-\(id)")
        switch id {
        case 1: onBrightness?(5)
        case 2: onBrightness?(-5)
        case 3: onBrightness?(1)
        case 4: onBrightness?(-1)
        case 5: onVolume?(5)
        case 6: onVolume?(-5)
        case 7: onMute?()
        case 8: onToggle?()
        default: break
        }
    }
    @discardableResult func enableMediaKeys(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        guard accessibilityTrusted else {
            disableMediaKeys()
            mediaKeyStatus = "permission-required"
            return false
        }
        if let eventTap, CFMachPortIsValid(eventTap), CGEvent.tapIsEnabled(tap: eventTap) {
            mediaKeyStatus = "active"
            return true
        }
        disableMediaKeys()
        // Apple keyboards send system-defined media events; keyboards in
        // standard function-key mode send ordinary F1/F2/F10/F11/F12 events.
        let mask = CGEventMask((1 << 14) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                         eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<KeyboardController>.fromOpaque(context).takeUnretainedValue()
            if type == .tapDisabledByTimeout {
                if AXIsProcessTrusted(), let tap = controller.eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type == .tapDisabledByUserInput {
                // Do not blindly re-enable a tap after permission is revoked.
                // The periodic health check reconnects it when access returns.
                return Unmanaged.passUnretained(event)
            }
            guard let keyEvent = NSEvent(cgEvent: event), controller.handleMediaKey(keyEvent) else {
                return Unmanaged.passUnretained(event)
            }
            return nil
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            mediaKeyStatus = "tap-failed"
            return false
        }
        eventTap = tap
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            disableMediaKeys(); mediaKeyStatus = "tap-failed"; return false
        }
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let enabled = CGEvent.tapIsEnabled(tap: tap)
        mediaKeyStatus = enabled ? "active" : "tap-failed"
        return enabled
    }

    /// Returns true for events consumed by the display controls, including
    /// releases so macOS does not also adjust the system output volume.
    @discardableResult func handleMediaKey(_ event: NSEvent) -> Bool {
        let code: Int
        let pressed: Bool
        let repeated: Bool
        switch event.type {
        case .systemDefined:
            guard event.subtype.rawValue == 8 else { return false }
            code = (event.data1 >> 16) & 0xffff
            let state = (event.data1 >> 8) & 0xff
            guard state == 0x0a || state == 0x0b else { return false }
            pressed = state == 0x0a
            repeated = event.data1 & 1 != 0
        case .keyDown, .keyUp:
            // Preserve modified function-key shortcuts used by other apps.
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
            switch Int(event.keyCode) {
            case kVK_F1: code = 3 // NX_KEYTYPE_BRIGHTNESS_DOWN
            case kVK_F2: code = 2 // NX_KEYTYPE_BRIGHTNESS_UP
            case kVK_F10: code = 7 // NX_KEYTYPE_MUTE
            case kVK_F11: code = 1 // NX_KEYTYPE_SOUND_DOWN
            case kVK_F12: code = 0 // NX_KEYTYPE_SOUND_UP
            default: return false
            }
            pressed = event.type == .keyDown
            repeated = pressed && event.isARepeat
        default: return false
        }
        let feature: Feature
        switch code {
        case 2, 3: feature = .brightness
        case 0, 1, 7: feature = .volume
        default: return false
        }
        // Leave unsupported controls to macOS (e.g. a display without speakers).
        guard canHandleMediaKey?(feature) == true else { return false }
        guard pressed else { return true }
        let step: Double = event.modifierFlags.contains(.shift) ? 1 : 5
        switch code {
        case 2, 3:
            onKeyboardAction?(code == 2 ? "brightness-key-up" : "brightness-key-down")
            onBrightness?(code == 2 ? step : -step)
        case 0, 1:
            onKeyboardAction?(code == 0 ? "volume-key-up" : "volume-key-down")
            onVolume?(code == 0 ? step : -step)
        case 7:
            // Holding mute must not repeatedly toggle between mute and unmute.
            if !repeated { onKeyboardAction?("volume-key-mute"); onMute?() }
        default: break
        }
        return true
    }
    func disableMediaKeys() {
        if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: false); CFMachPortInvalidate(eventTap) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        eventTap = nil; tapSource = nil
        mediaKeyStatus = "disabled"
    }
    deinit {
        references.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
        disableMediaKeys()
    }
}
