import AppKit
import Carbon

private func media(_ code: Int, down: Bool = true, repeated: Bool = false,
                   modifiers: NSEvent.ModifierFlags = [], subtype: Int16 = 8) -> NSEvent {
    let data = (code << 16) | ((down ? 0x0a : 0x0b) << 8) | (repeated ? 1 : 0)
    // Round-trip through CGEvent, as the real event tap does.
    let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: modifiers,
                                  timestamp: 0, windowNumber: 0, context: nil,
                                  subtype: subtype, data1: data, data2: -1)!
    return NSEvent(cgEvent: event.cgEvent!)!
}

private func function(_ code: Int, down: Bool = true, repeated: Bool = false,
                      modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
    NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: modifiers,
                    timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                    isARepeat: repeated, keyCode: UInt16(code))!
}

@main struct KeyboardTests {
    static func main() {
        let keyboard = KeyboardController()
        var available: Set<Feature> = [.brightness, .volume]
        var brightness: [Double] = [], volume: [Double] = [], actions: [String] = []
        var muteCount = 0
        keyboard.canHandleMediaKey = { available.contains($0) }
        keyboard.onBrightness = { brightness.append($0) }
        keyboard.onVolume = { volume.append($0) }
        keyboard.onMute = { muteCount += 1 }
        keyboard.onKeyboardAction = { actions.append($0) }

        assert(keyboard.handleMediaKey(media(0)))
        assert(keyboard.handleMediaKey(media(1)))
        assert(keyboard.handleMediaKey(media(0, repeated: true)))
        assert(keyboard.handleMediaKey(media(1, modifiers: .shift)))
        assert(volume == [5, -5, 5, -1])
        assert(keyboard.handleMediaKey(media(7)))
        assert(keyboard.handleMediaKey(media(7, repeated: true)))
        assert(keyboard.handleMediaKey(media(7, down: false)))
        assert(muteCount == 1)
        assert(keyboard.handleMediaKey(media(7)))
        assert(muteCount == 2)
        assert(keyboard.handleMediaKey(media(2)))
        assert(keyboard.handleMediaKey(media(3, modifiers: .shift)))
        assert(brightness == [5, -1])
        assert(actions == ["volume-key-up", "volume-key-down", "volume-key-up", "volume-key-down",
                           "volume-key-mute", "volume-key-mute", "brightness-key-up", "brightness-key-down"])

        // External keyboards can send ordinary F1/F2 in standard function-key
        // mode, while brightness mode sends the system-defined events above.
        brightness = []
        assert(keyboard.handleMediaKey(function(kVK_F1)))
        assert(keyboard.handleMediaKey(function(kVK_F2)))
        assert(keyboard.handleMediaKey(function(kVK_F1, repeated: true)))
        assert(keyboard.handleMediaKey(function(kVK_F2, repeated: true, modifiers: [.shift, .function])))
        assert(brightness == [-5, 5, -5, 1])
        assert(Array(actions.suffix(4)) == ["brightness-key-down", "brightness-key-up", "brightness-key-down", "brightness-key-up"])

        // Magic Keyboard brightness mode can arrive as dedicated virtual
        // keycodes, rather than F1/F2 or system-defined media events.
        brightness = []
        assert(keyboard.handleMediaKey(function(145)))
        assert(keyboard.handleMediaKey(function(144)))
        assert(keyboard.handleMediaKey(function(145, repeated: true)))
        assert(keyboard.handleMediaKey(function(144, modifiers: [.shift, .function])))
        assert(brightness == [-5, 5, -5, 1])

        volume = []
        assert(keyboard.handleMediaKey(function(kVK_F10)))
        assert(keyboard.handleMediaKey(function(kVK_F10, repeated: true)))
        assert(keyboard.handleMediaKey(function(kVK_F11)))
        assert(keyboard.handleMediaKey(function(kVK_F12)))
        assert(keyboard.handleMediaKey(function(kVK_F12, repeated: true, modifiers: [.shift, .function])))
        assert(volume == [-5, 5, 1] && muteCount == 3)
        let actionCount = actions.count
        for code in [0, 1, 2, 3, 7] { assert(keyboard.handleMediaKey(media(code, down: false))) }
        for code in [kVK_F1, kVK_F2, 144, 145, kVK_F10, kVK_F11, kVK_F12] {
            assert(keyboard.handleMediaKey(function(code, down: false)))
            for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
                assert(!keyboard.handleMediaKey(function(code, modifiers: modifier)))
            }
        }
        assert(actions.count == actionCount)
        assert(!keyboard.handleMediaKey(media(16))) // Play/pause belongs to macOS.
        assert(!keyboard.handleMediaKey(media(0, subtype: 0)))
        assert(!keyboard.handleMediaKey(function(kVK_F9)))
        assert(!keyboard.handleMediaKey(function(kVK_ANSI_A)))

        available = [.brightness]
        assert(!keyboard.handleMediaKey(media(0)))
        assert(!keyboard.handleMediaKey(media(7)))
        assert(!keyboard.handleMediaKey(function(kVK_F11)))
        available = [.volume]
        assert(!keyboard.handleMediaKey(media(2)))
        assert(!keyboard.handleMediaKey(function(kVK_F1)))
        assert(!keyboard.handleMediaKey(function(kVK_F2)))
        assert(!keyboard.handleMediaKey(function(144)))
        assert(!keyboard.handleMediaKey(function(145)))
        assert(keyboard.handleMediaKey(media(1))) // Volume works even without brightness.
        available = []
        assert(!keyboard.handleMediaKey(function(kVK_F10)))
        assert(!keyboard.handleMediaKey(media(1)))
        assert(muteCount == 3)
        assert((keyboard.diagnostics["lastBrightnessEvent"] as? [String: Any])?["result"] as? String == "brightness-unavailable")
        let count = keyboard.diagnostics["brightnessEventCount"] as? Int
        assert(!keyboard.handleMediaKey(function(kVK_ANSI_A)))
        assert(!keyboard.handleMediaKey(media(16)))
        assert(keyboard.diagnostics["brightnessEventCount"] as? Int == count)
        available = [.brightness]
        assert(keyboard.handleMediaKey(function(kVK_F1)))
        assert((keyboard.diagnostics["lastBrightnessEvent"] as? [String: Any])?["result"] as? String == "consumed")
        assert(!keyboard.handleMediaKey(function(kVK_F2, modifiers: .command)))
        assert((keyboard.diagnostics["lastBrightnessEvent"] as? [String: Any])?["result"] as? String == "unrecognized-or-modified")
        print("Keyboard tests passed: media keys, F1/F2, dedicated brightness keycodes 144/145, F10–F12, fine steps, repeats, releases, modifier shortcuts, per-feature availability, brightness-only diagnostics")
    }
}
