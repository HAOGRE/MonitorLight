import Foundation

final class FakeDDC: DDCProviding {
    typealias Completion = (Result<Data, Error>) -> Void
    var calls: [([String], Completion)] = []
    func perform(_ arguments: [String], completion: @escaping Completion) { calls.append((arguments, completion)) }
    func reply(_ object: Any, at index: Int = 0) {
        calls.remove(at: index).1(.success(try! JSONSerialization.data(withJSONObject: object)))
    }
    func fail() { calls.removeFirst().1(.failure(DDCFailure(message: "simulated read-back failure"))) }
}
final class FakeDimming: SoftwareDimmingProviding {
    var levels: [UInt32: Double] = [:]
    func set(displayID: UInt32, percent: Double) -> Bool { levels[displayID] = percent; return true }
    func remove(displayID: UInt32) { levels.removeValue(forKey: displayID) }
    func reconcile() {}
    func resetAll() { levels.removeAll() }
    func diagnostics() -> [[String: Any]] { [] }
}
func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.17)) }
func probe(_ brightness: Int = 70) -> [String: Any] {
    ["brightness": ["current": brightness, "maximum": 100], "contrast": ["current": 50, "maximum": 100], "volume": ["current": 40, "maximum": 100]]
}
@main struct ModelTests {
    static func main() {
        UserDefaults.standard.removeObject(forKey: "selectedDisplay")
        defer { UserDefaults.standard.removeObject(forKey: "selectedDisplay") }
        let client = FakeDDC(), model = MonitorModel(client: FakeDDC(), writesDiagnostics: false)
        _ = model // Verify model construction requires no display or permission.
        let tested = MonitorModel(client: client, writesDiagnostics: false)
        tested.discover()
        client.reply([["id": 99998, "uuid": "test-a", "name": "Test A", "ddc": true],
                      ["id": 99999, "uuid": "test-b", "name": "Test B", "ddc": true]])
        client.reply(probe())
        assert(tested.ready && !tested.softwareBrightness)

        tested.set(.brightness, percent: 10)
        tested.set(.brightness, percent: 20)
        tested.set(.brightness, percent: 30)
        pump()
        assert(client.calls.count == 1 && client.calls[0].0 == ["set", "test-a", "brightness", "30"])
        tested.set(.brightness, percent: 45)
        tested.set(.brightness, percent: 55)
        pump()
        assert(client.calls.count == 1)
        client.reply(["current": 30, "maximum": 100, "verified": true])
        assert(client.calls.count == 1 && client.calls[0].0.last == "55")
        client.reply(["current": 55, "maximum": 100, "verified": true])
        assert(tested.controls[.brightness]?.value?.current == 55 && tested.controls[.brightness]?.requested == nil && !tested.hasPendingWrites)

        // Opening the panel then dragging must not let an older read replace
        // the new UI request or the final confirmed value.
        tested.refresh()
        tested.set(.brightness, percent: 65)
        pump()
        client.reply(probe(20))
        assert(tested.controls[.brightness]?.percent == 65)
        client.reply(["current": 65, "maximum": 100, "verified": true])

        tested.brightnessMode = .hardware
        tested.set(.brightness, percent: 90)
        pump(); client.fail()
        assert(tested.controls[.brightness]?.percent == 65)
        assert(tested.controls[.brightness]?.error != nil && !tested.hasPendingWrites)
        client.reply(["current": 60, "maximum": 100])
        assert(tested.controls[.brightness]?.percent == 60)

        tested.set(.brightness, percent: 80)
        pump()
        tested.select("test-b")
        client.reply(probe(25), at: 1)
        client.reply(["current": 80, "maximum": 100, "verified": true])
        assert(tested.selectedUUID == "test-b" && tested.controls[.brightness]?.percent == 25)

        tested.toggleMute(); pump()
        assert(client.calls[0].0 == ["set", "test-b", "volume", "0"])
        client.reply(["current": 0, "maximum": 100, "verified": true])
        tested.toggleMute(); pump()
        assert(client.calls[0].0.last == "40")
        client.reply(["current": 40, "maximum": 100, "verified": true])

        tested.set(.brightness, percent: -20); pump()
        assert(client.calls[0].0.last == "0")
        client.reply(["current": 0, "maximum": 100, "verified": true])
        tested.set(.brightness, percent: 200); pump()
        assert(client.calls[0].0.last == "100")
        client.reply(["current": 100, "maximum": 100, "verified": true])

        tested.discover(); client.reply([])
        assert(!tested.ready && !tested.isLoading && tested.message != nil)
        let staleClient = FakeDDC()
        let fresh = MonitorModel(client: staleClient, writesDiagnostics: false)
        fresh.selectedUUID = "test-fresh"
        fresh.controls[.volume] = ControlState(value: DDCValue(current: 100, maximum: 100))
        fresh.adjust(.volume, by: -5); fresh.adjust(.volume, by: -5)
        assert(staleClient.calls.count == 1 && staleClient.calls[0].0 == ["get", "test-fresh", "volume"])
        staleClient.reply(["current": 30, "maximum": 100]); pump()
        assert(staleClient.calls[0].0 == ["set", "test-fresh", "volume", "20"])
        staleClient.reply(["current": 20, "maximum": 100, "verified": true])
        let bad = Data("{\"current\":1,\"maximum\":0}".utf8)
        assert((try? JSONDecoder().decode(DDCValue.self, from: bad)) == nil)
        assert(ControlCommand(url: URL(string: "monitorlight://brightness/50")!) == .brightness(50))
        assert(ControlCommand(url: URL(string: "monitorlight://adjust-brightness/-5")!) == .adjustBrightness(-5))
        assert(ControlCommand(url: URL(string: "monitorlight://brightness/101")!) == nil)
        assert(ControlCommand(url: URL(string: "monitorlight://brightness/nan")!) == nil)
        assert(ControlCommand(url: URL(string: "https://brightness/50")!) == nil)
        // A hardware picture mode is a raw value (531), never a percentage.
        // Failed or stale callbacks must not claim a different mode is active.
        let settingsClient = FakeDDC(), settings = DisplaySettingsModel(client: FakeDDC())
        _ = settings
        let advanced = DisplaySettingsModel(client: settingsClient)
        defer {
            for uuid in ["test-modes-a", "test-modes-b"] {
                UserDefaults.standard.removeObject(forKey: "lowBlueScene.\(uuid)")
            }
        }
        advanced.configure(display: DisplayInfo(id: 99998, uuid: "test-modes-a", name: "BenQ EW3270U", ddc: true))
        settingsClient.reply(["picture-mode": ["current": 531, "maximum": 1043], "sharpness": ["current": 5, "maximum": 10]])
        assert(advanced.currentModeTitle == "低蓝光 · 网上冲浪")
        advanced.set("picture-mode", value: 787)
        assert(settingsClient.calls[0].0 == ["set", "test-modes-a", "picture-mode", "787"])
        assert(advanced.currentModeValue == 531 && advanced.isWriting)
        settingsClient.fail()
        assert(advanced.currentModeValue == 531 && !advanced.isWriting && advanced.error != nil)
        settingsClient.reply(["picture-mode": ["current": 531, "maximum": 1043]])
        advanced.set("picture-mode", value: 275)
        advanced.configure(display: DisplayInfo(id: 99999, uuid: "test-modes-b", name: "BenQ EW3270U", ddc: true))
        settingsClient.reply(["picture-mode": ["current": 5, "maximum": 1043]], at: 1)
        settingsClient.reply(["current": 275, "maximum": 1043])
        assert(advanced.currentModeValue == 5 && advanced.currentModeTitle == "游戏")
        advanced.refresh()
        settingsClient.reply(["picture-mode": ["current": 12, "maximum": 1043]])
        assert(advanced.currentModeTitle == "sRGB / Rec.709")
        advanced.refresh()
        settingsClient.reply(["picture-mode": ["current": 255, "maximum": 1043]])
        assert(advanced.currentMode == nil && advanced.currentModeTitle == "HDR 或显示器专用模式")
        advanced.refresh()
        settingsClient.reply(["picture-mode": ["current": 1043, "maximum": 1043]])
        assert(advanced.currentPictureModeID == "lowblue")
        assert(advanced.pictureModeChoices.filter { $0.id == "lowblue" }.count == 1)
        assert(!advanced.pictureModeChoices.contains(where: \.isLowBlueLight))
        advanced.selectPictureMode(id: "game")
        settingsClient.reply(["current": 5, "maximum": 1043])
        settingsClient.reply(["picture-mode": ["current": 5, "maximum": 1043]])
        advanced.selectPictureMode(id: "lowblue")
        assert(settingsClient.calls[0].0 == ["set", "test-modes-b", "picture-mode", "1043"])
        settingsClient.fail()
        assert(advanced.currentPictureModeID == "game")
        settingsClient.reply(["picture-mode": ["current": 5, "maximum": 1043]])

        // Input changes stay at the last confirmed value until the display
        // acknowledges the exact target. A failed/stale reply cannot relabel it.
        let inputClient = FakeDDC(), inputs = DisplaySettingsModel(client: inputClient)
        let inputDisplay = DisplayInfo(id: 99996, uuid: "test-input", name: "BenQ EW3270U", ddc: true)
        inputs.configure(display: inputDisplay)
        inputClient.reply(["input-source": ["current": 16, "maximum": 18]])
        assert(inputs.currentInputSource?.title == "DisplayPort")
        inputs.selectInputSource(value: 16)
        inputs.selectInputSource(value: 27)
        assert(inputClient.calls.isEmpty)
        var writeNotification = false
        inputs.onChange = { if inputs.isWriting { writeNotification = true } }
        inputs.selectInputSource(value: 17)
        assert(writeNotification && inputs.isWriting && inputs.values["input-source"]?.current == 16)
        assert(inputClient.calls[0].0 == ["set", "test-input", "input-source", "17"])
        inputs.selectInputSource(value: 18)
        assert(inputClient.calls.count == 1) // do not queue duplicate changes
        inputClient.fail()
        assert(inputs.values["input-source"]?.current == 16 && inputs.error != nil)
        inputClient.reply(["input-source": ["current": 16, "maximum": 18]])
        inputs.selectInputSource(value: 17)
        inputClient.reply(["current": 16, "maximum": 18]) // mismatched readback
        assert(inputs.values["input-source"]?.current == 16 && inputs.error != nil)
        inputClient.reply(["input-source": ["current": 16, "maximum": 18]])
        inputs.selectInputSource(value: 17)
        inputClient.reply(["current": 17, "maximum": 18, "verified": true])
        assert(inputs.currentInputSource?.title == "HDMI 1" && inputs.error == nil)
        inputClient.reply(["input-source": ["current": 17, "maximum": 18]])
        inputs.refresh()
        inputs.selectInputSource(value: 16) // explicit choice during background read
        assert(inputClient.calls.count == 2 && inputs.isWriting)
        inputClient.reply(["input-source": ["current": 18, "maximum": 18]])
        assert(inputs.values["input-source"]?.current == 17 && inputs.isWriting)
        inputClient.reply(["current": 16, "maximum": 18])
        assert(inputs.currentInputSource?.title == "DisplayPort")
        inputClient.reply(["input-source": ["current": 16, "maximum": 18]])
        inputs.refresh()
        inputClient.reply(["input-source": ["current": 18, "maximum": 18]])
        assert(inputs.currentInputSource?.title == "HDMI 2") // physical change
        inputs.selectInputSource(value: 16)
        inputs.configure(display: nil)
        inputClient.reply(["current": 16, "maximum": 18])
        assert(inputs.values.isEmpty && !inputs.supported && !inputs.isWriting)
        print("Input source tests passed: exact readback, failure, external change, stale display, write notification")

        // A physical mode change must reconsider an automatic software fallback,
        // even when another refresh was already in flight. No writes are needed.
        let syncClient = FakeDDC(), shade = FakeDimming()
        let sync = MonitorModel(client: syncClient, writesDiagnostics: false, dimming: shade)
        let syncUUID = "test-mode-sync"
        let syncKeys = ["brightnessMode.\(syncUUID)", "softwareBrightness.\(syncUUID)", "lowBlueScene.\(syncUUID)"]
        syncKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { syncKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        sync.discover()
        syncClient.reply([["id": 99997, "uuid": syncUUID, "name": "BenQ EW3270U", "ddc": true]])
        syncClient.reply(probe(70))
        syncClient.reply(["picture-mode": ["current": 0, "maximum": 1043]])
        assert(syncClient.calls.isEmpty) // initial observation is not a mode change
        sync.softwareBrightness = true
        sync.set(.brightness, percent: 35)
        sync.refresh()
        sync.displaySettings.refresh()
        syncClient.reply(["picture-mode": ["current": 5, "maximum": 1043]], at: 1)
        assert(syncClient.calls.count == 1) // ordinary probe still running
        syncClient.reply(probe(90))
        assert(sync.softwareBrightness && sync.controls[.brightness]?.percent == 35)
        assert(syncClient.calls.count == 1 && syncClient.calls[0].0 == ["probe", syncUUID])
        syncClient.reply(probe(90))
        assert(!sync.softwareBrightness && sync.controls[.brightness]?.percent == 90 && shade.levels.isEmpty)
        sync.displaySettings.refresh()
        syncClient.reply(["picture-mode": ["current": 5, "maximum": 1043]])
        assert(syncClient.calls.isEmpty) // unchanged modes do not repeatedly recheck

        // A new software key/slider adjustment wins over an older mode probe.
        sync.softwareBrightness = true
        sync.set(.brightness, percent: 40)
        sync.refresh(reconsiderBrightness: true)
        sync.set(.brightness, percent: 30)
        syncClient.reply(probe(80))
        assert(sync.softwareBrightness && sync.controls[.brightness]?.percent == 30 && shade.levels[99997] == 30)

        // The same precedence applies while the recheck is still queued.
        sync.refresh()
        sync.refresh(reconsiderBrightness: true)
        sync.set(.brightness, percent: 25)
        syncClient.reply(probe(80))
        assert(syncClient.calls.isEmpty && sync.softwareBrightness && sync.controls[.brightness]?.percent == 25)

        // Explicit software mode remains software after a physical mode change.
        UserDefaults.standard.set("software", forKey: syncKeys[0])
        sync.displaySettings.refresh()
        syncClient.reply(["picture-mode": ["current": 11, "maximum": 1043]])
        syncClient.reply(probe(80))
        assert(sync.softwareBrightness && sync.controls[.brightness]?.percent == 25)
        assert(shade.levels[99997] == 25 && syncClient.calls.isEmpty)

        // Slider geometry: 292pt wide track with a 30pt symbol cap → 262pt of travel.
        let w: CGFloat = 292, cap: CGFloat = 30
        assert(SliderMath.dragValue(start: 40, translation: 0, width: w, cap: cap) == 40) // grabbing never jumps
        assert(abs(SliderMath.dragValue(start: 40, translation: 131, width: w, cap: cap) - 90) < 0.001)
        assert(SliderMath.dragValue(start: 40, translation: -1000, width: w, cap: cap) == 0)
        assert(SliderMath.dragValue(start: 90, translation: 1000, width: w, cap: cap) == 100)
        assert(SliderMath.clickValue(x: cap / 2, width: w, cap: cap) == 0)
        assert(SliderMath.clickValue(x: w - cap / 2, width: w, cap: cap) == 100)
        assert(abs(SliderMath.clickValue(x: cap / 2 + 131, width: w, cap: cap) - 50) < 0.001)
        assert(SliderMath.clickValue(x: -20, width: w, cap: cap) == 0)
        assert(SliderMath.fillWidth(value: 0, width: w, cap: cap) == cap) // symbol stays inside the fill
        assert(SliderMath.fillWidth(value: 100, width: w, cap: cap) == w)
        assert(SliderMath.fillWidth(value: 50, width: w, cap: cap) == cap + 131)
        assert(SliderMath.dragValue(start: 10, translation: 50, width: 20, cap: cap) == 10) // degenerate width
        let presets: [Double] = [35, 60, 85]
        assert(SliderMath.crossesDetent(from: 30, to: 36, detents: presets))
        assert(SliderMath.crossesDetent(from: 62, to: 60, detents: presets))
        assert(!SliderMath.crossesDetent(from: 60, to: 62, detents: presets)) // leaving a detent is silent
        assert(!SliderMath.crossesDetent(from: 40, to: 50, detents: presets))
        assert(SliderMath.crossesDetent(from: 3, to: 0, detents: []) && SliderMath.crossesDetent(from: 97, to: 100, detents: []))
        var wheel = SliderMath.ScrollAccumulator()
        assert(wheel.add(deltaX: 0, deltaY: 1, inverted: false, precise: false) == 2)   // mouse notch up → +2%
        assert(wheel.add(deltaX: 0, deltaY: -1, inverted: false, precise: false) == -2)
        var pad = SliderMath.ScrollAccumulator()
        assert(pad.add(deltaX: 0, deltaY: -3, inverted: true, precise: true) == 0)      // fingers up, natural: sub-step
        assert(pad.add(deltaX: 0, deltaY: -3, inverted: true, precise: true) == 1)      // accumulates to +1%
        assert(abs(pad.remainder - 0.5) < 0.001)
        pad.reset(); assert(pad.remainder == 0)
        assert(pad.add(deltaX: 8, deltaY: 1, inverted: true, precise: true) == 2)       // horizontal swipe right
        // Auto fallback recovers once the display unlocks brightness (e.g. B.I.+ turned off).
        let lockClient = FakeDDC(), lockShade = FakeDimming()
        let locked = MonitorModel(client: lockClient, writesDiagnostics: false, dimming: lockShade)
        let lockUUID = "test-bi-lock"
        let lockKeys = ["brightnessMode.\(lockUUID)", "softwareBrightness.\(lockUUID)"]
        lockKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        defer { lockKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        locked.discover()
        lockClient.reply([["id": 99996, "uuid": lockUUID, "name": "Locked", "ddc": true]])
        lockClient.reply(["brightness": ["error": "locked"], "volume": ["current": 40, "maximum": 100]])
        assert(locked.isAutoSoftwareFallback && lockShade.levels[99996] == 100)
        locked.refresh(reconsiderBrightness: locked.isAutoSoftwareFallback)
        lockClient.reply(["brightness": ["error": "locked"], "volume": ["current": 40, "maximum": 100]])
        assert(locked.isAutoSoftwareFallback) // still locked: stays on the overlay
        locked.refresh(reconsiderBrightness: locked.isAutoSoftwareFallback)
        lockClient.reply(probe(70))
        assert(!locked.softwareBrightness && locked.controls[.brightness]?.value?.current == 70 && lockShade.levels.isEmpty)
        assert(lockClient.calls.isEmpty) // recovery is read-only
        print("Brightness lock recovery tests passed: stays on overlay while locked, returns to hardware when unlocked, no writes")
        print("Slider math tests passed: relative drag, click jump, fill cap, detents, wheel and trackpad scrolling")
        print("Model tests passed: coalescing, read/write races, failure rollback, display switching, mute restore, bounds, disconnect")
        print("Display setting tests passed: raw mode values, rollback, stale display replies, ambiguous and unrecognized mode labels")
        print("Physical mode sync tests passed: deferred brightness recheck, software input precedence, explicit software preference")
    }
}
