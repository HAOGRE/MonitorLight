import AppKit
import SwiftUI
import ServiceManagement

enum BrightnessMode: String, CaseIterable, Identifiable {
    case auto, hardware, software
    var id: String { rawValue }
}

final class MonitorModel: ObservableObject {
    @Published var displays: [DisplayInfo] = []
    @Published var selectedUUID: String = UserDefaults.standard.string(forKey: "selectedDisplay") ?? ""
    @Published var controls: [Feature: ControlState] = [:]
    @Published var isLoading = false
    @Published var message: String?
    @Published var hotkeyMessage: String?
    @Published var mediaKeysEnabled = false
    @Published var mediaKeysRequested = UserDefaults.standard.object(forKey: "useMediaKeys") as? Bool != false
    @Published var mediaKeyMessage = L("正在检查亮度键…")
    private var keyboardDiagnostics: [String: Any] = [:]
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var showPercentage = UserDefaults.standard.bool(forKey: "showPercentage")
    @Published var softwareBrightness = false
    @Published var brightnessMode = BrightnessMode.auto
    let dimming: SoftwareDimmingProviding
    let displaySettings: DisplaySettingsModel
    var onChange: (() -> Void)?
    var onHUD: ((String, Double, String) -> Void)?
    private let client: DDCProviding
    private let writesDiagnostics: Bool
    private var generation = 0
    private var queued: [Feature: DispatchWorkItem] = [:]
    private var inFlight: Set<Feature> = []
    private var requests: [Feature: Int] = [:]
    private var revisions: [Feature: Int] = [:]
    private var isRefreshing = false
    private var pendingBrightnessRecheck = false
    private var lastVolume: [String: Double] = [:]
    private var lastRead: [Feature: Date] = [:]
    private var keyboardDeltas: [Feature: Double] = [:]
    private var muteReadInFlight = false
    private var pendingMute = false
    private var keyboardActionCount = 0
    private var lastKeyboardAction: String?
    private var diagnosticsWrite: DispatchWorkItem?

    init(client: DDCProviding = DDCClient(), writesDiagnostics: Bool = true,
         dimming: SoftwareDimmingProviding = SoftwareDimming()) {
        self.client = client
        self.dimming = dimming
        self.writesDiagnostics = writesDiagnostics
        self.displaySettings = DisplaySettingsModel(client: client)
        self.displaySettings.onChange = { [weak self] in self?.notify() }
        self.displaySettings.onModeChanged = { [weak self] in self?.refresh(reconsiderBrightness: true) }
    }

    var selectedDisplay: DisplayInfo? { displays.first { $0.uuid == selectedUUID } }
    var ready: Bool { controls[.brightness]?.value != nil }
    /// Automatic mode fell back to the overlay because the display refused DDC
    /// brightness (B.I.+, HDR, some picture modes). Worth re-checking periodically.
    var isAutoSoftwareFallback: Bool { brightnessMode == .auto && softwareBrightness }
    var hasPendingWrites: Bool { !inFlight.isEmpty || !requests.isEmpty || displaySettings.isWriting }
    func discover() {
        guard !isLoading else { return }
        resetSession()
        let token = generation
        dimming.reconcile()
        notify()
        client.perform(["list"]) { [weak self] result in
            guard let self, self.generation == token else { return }
            do {
                self.displays = try JSONDecoder().decode([DisplayInfo].self, from: result.get())
                if !self.displays.contains(where: { $0.uuid == self.selectedUUID }) {
                    self.selectedUUID = self.displays.first(where: { $0.ddc })?.uuid ?? self.displays.first?.uuid ?? ""
                }
                guard self.selectedDisplay != nil else {
                    self.displaySettings.configure(display: nil)
                    self.isLoading = false
                    self.message = L("未发现外接显示器。连接后会自动检测。")
                    self.notify(); return
                }
                self.loadControls(token: token)
            } catch { self.isLoading = false; self.message = error.localizedDescription; self.notify() }
        }
    }
    func select(_ uuid: String) {
        guard uuid != selectedUUID else { return }
        selectedUUID = uuid
        UserDefaults.standard.set(uuid, forKey: "selectedDisplay")
        resetSession()
        loadControls(token: generation)
    }
    /// Invalidates replies and writes that belong to the previous target.
    private func resetSession() {
        generation += 1
        queued.values.forEach { $0.cancel() }; queued.removeAll()
        requests.removeAll(); inFlight.removeAll(); revisions.removeAll()
        keyboardDeltas.removeAll(); lastRead.removeAll()
        muteReadInFlight = false; pendingMute = false
        isRefreshing = false; pendingBrightnessRecheck = false
        controls = [:]; message = nil; isLoading = true
        displaySettings.configure(display: nil)
    }
    private func loadControls(token: Int) {
        let uuid = selectedUUID
        client.perform(["probe", uuid]) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.isLoading = false
            do {
                let json = try JSONSerialization.jsonObject(with: result.get()) as? [String: [String: Any]] ?? [:]
                for feature in Feature.allCases {
                    let entry = json[feature.rawValue] ?? [:]
                    if let current = entry["current"] as? Int, let maximum = entry["maximum"] as? Int, maximum > 0, current <= maximum {
                        self.controls[feature] = ControlState(value: DDCValue(current: current, maximum: maximum))
                        self.lastRead[feature] = Date()
                    } else { self.controls[feature] = ControlState(error: entry["error"] as? String ?? L("显示器不支持此项设置。")) }
                }
                self.configureBrightness()
            } catch {
                for feature in Feature.allCases { self.controls[feature] = ControlState(error: error.localizedDescription) }
                self.configureBrightness()
            }
            self.notify()
            self.displaySettings.configure(display: self.selectedDisplay)
        }
    }
    // Refresh read-only state when opening the popover, without overwriting a
    // slider the user has touched since this request began.
    func refresh(reconsiderBrightness: Bool = false) {
        if reconsiderBrightness { pendingBrightnessRecheck = true }
        guard !isLoading, !isRefreshing, !hasPendingWrites, selectedDisplay != nil else { return }
        let reconsiderBrightness = pendingBrightnessRecheck
        pendingBrightnessRecheck = false
        isRefreshing = true
        let token = generation, snapshot = revisions
        client.perform(["probe", selectedUUID]) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.isRefreshing = false
            if case .success(let data) = result,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] {
                for feature in Feature.allCases where self.revisions[feature] == snapshot[feature] && !self.inFlight.contains(feature) && self.requests[feature] == nil {
                    if feature == .brightness && self.softwareBrightness && !reconsiderBrightness { continue }
                    let entry = json[feature.rawValue] ?? [:]
                    if let current = entry["current"] as? Int, let maximum = entry["maximum"] as? Int, maximum > 0, current <= maximum {
                        self.controls[feature] = ControlState(value: DDCValue(current: current, maximum: maximum))
                        self.lastRead[feature] = Date()
                    } else {
                        self.controls[feature] = ControlState(error: entry["error"] as? String ?? L("暂时无法读取此项设置。"))
                    }
                }
                let brightnessUntouched = self.revisions[.brightness] == snapshot[.brightness] &&
                    !self.inFlight.contains(.brightness) && self.requests[.brightness] == nil
                if !self.ready || (reconsiderBrightness && brightnessUntouched) { self.configureBrightness() }
            } else if case .failure(let error) = result { self.message = error.localizedDescription }
            self.notify()
        }
    }
    func set(_ feature: Feature, percent: Double, showHUD: Bool = false) {
        guard let value = controls[feature]?.value else { return }
        let clamped = min(100, max(0, percent)).rounded()
        // Software adjustments also supersede any in-flight hardware probe.
        revisions[feature, default: 0] += 1
        if feature == .brightness { pendingBrightnessRecheck = false }
        if feature == .brightness && softwareBrightness {
            guard let display = selectedDisplay, dimming.set(displayID: display.id, percent: clamped) else {
                controls[.brightness]?.isWriting = false
                controls[.brightness]?.requested = nil
                message = L("显示器已断开，请重新检测。"); notify(); return
            }
            controls[.brightness] = ControlState(value: DDCValue(current: Int(clamped.rounded()), maximum: 100))
            UserDefaults.standard.set(clamped, forKey: "softwareBrightness.\(selectedUUID)")
            if showHUD { onHUD?(L("亮度 · 软件调光"), clamped, feature.symbol) }
            notify(); return
        }
        let raw = Int((clamped * Double(value.maximum) / 100).rounded())
        requests[feature] = raw
        controls[feature]?.requested = Double(raw) / Double(value.maximum) * 100
        controls[feature]?.isWriting = true
        controls[feature]?.error = nil
        if showHUD { onHUD?(feature.title, clamped, feature.symbol) }
        // Throttle the first write; do not postpone it indefinitely while a
        // slider is dragged or a key is held. In-flight writes coalesce below.
        if queued[feature] == nil && !inFlight.contains(feature) {
            let work = DispatchWorkItem { [weak self] in self?.flush(feature) }
            queued[feature] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        notify()
    }
    private func flush(_ feature: Feature) {
        queued.removeValue(forKey: feature)
        guard !inFlight.contains(feature), let raw = requests.removeValue(forKey: feature) else { return }
        inFlight.insert(feature)
        let token = generation, uuid = selectedUUID
        client.perform(["set", uuid, feature.rawValue, String(raw)]) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.inFlight.remove(feature)
            do {
                let data = try result.get()
                let value = try JSONDecoder().decode(DDCValue.self, from: data)
                self.controls[feature]?.value = value
                self.lastRead[feature] = Date()
                self.controls[feature]?.error = nil
            } catch {
                if feature == .brightness && self.brightnessMode == .auto, let maximum = self.controls[feature]?.value?.maximum {
                    let latest = self.requests.removeValue(forKey: feature) ?? raw
                    self.queued[feature]?.cancel()
                    self.softwareBrightness = true
                    self.message = L("显示器未接受硬件亮度，已改用软件调光。")
                    self.set(.brightness, percent: Double(latest) * 100 / Double(maximum), showHUD: true)
                    self.notify()
                    return
                }
                self.controls[feature]?.error = error.localizedDescription
                self.onHUD?(L("%@未生效", feature.title), self.controls[feature]?.value?.percent ?? 0, "exclamationmark.triangle")
            }
            if self.requests[feature] != nil { self.flush(feature) }
            else {
                self.controls[feature]?.requested = nil
                self.controls[feature]?.isWriting = false
                if self.controls[feature]?.error != nil { self.refreshAfterFailure(feature, token: token) }
            }
            self.notify()
        }
    }
    private func refreshAfterFailure(_ feature: Feature, token: Int) {
        let revision = revisions[feature]
        client.perform(["get", selectedUUID, feature.rawValue]) { [weak self] result in
            guard let self, self.generation == token, self.revisions[feature] == revision else { return }
            if case .success(let data) = result, let value = try? JSONDecoder().decode(DDCValue.self, from: data) {
                self.controls[feature]?.value = value
            }
            self.notify()
        }
    }
    func adjust(_ feature: Feature, by step: Double) {
        guard let state = controls[feature], state.value != nil else {
            onHUD?(L("暂时无法调节%@", feature.title), 0, "exclamationmark.triangle")
            return
        }
        if feature == .brightness && softwareBrightness || state.isWriting ||
            (lastRead[feature].map { Date().timeIntervalSince($0) < 2 } ?? false) {
            set(feature, percent: state.percent + step, showHUD: true)
            return
        }
        // A physical OSD adjustment must not make the next keyboard press jump
        // to an old cached value (particularly important for speaker volume).
        let alreadyReading = keyboardDeltas[feature] != nil
        keyboardDeltas[feature, default: 0] += step
        guard !alreadyReading else { return }
        let token = generation, revision = revisions[feature]
        client.perform(["get", selectedUUID, feature.rawValue]) { [weak self] result in
            guard let self, self.generation == token else { return }
            let delta = self.keyboardDeltas.removeValue(forKey: feature) ?? 0
            guard self.revisions[feature] == revision else { return }
            do {
                let value = try JSONDecoder().decode(DDCValue.self, from: result.get())
                self.controls[feature]?.value = value
                self.lastRead[feature] = Date()
                self.set(feature, percent: value.percent + delta, showHUD: true)
            } catch {
                self.controls[feature]?.error = error.localizedDescription
                self.onHUD?(L("%@暂不可用", feature.title), state.percent, "exclamationmark.triangle")
                self.notify()
            }
        }
    }
    func toggleMute() {
        guard let state = controls[.volume], state.value != nil else { return }
        if state.isWriting || (lastRead[.volume].map { Date().timeIntervalSince($0) < 2 } ?? false) {
            applyMuteToCurrentValue(); return
        }
        pendingMute.toggle()
        guard !muteReadInFlight else { return }
        muteReadInFlight = true
        let token = generation, revision = revisions[.volume]
        client.perform(["get", selectedUUID, "volume"]) { [weak self] result in
            guard let self, self.generation == token else { return }
            self.muteReadInFlight = false
            let shouldMute = self.pendingMute; self.pendingMute = false
            guard self.revisions[.volume] == revision else { return }
            do {
                let value = try JSONDecoder().decode(DDCValue.self, from: result.get())
                self.controls[.volume]?.value = value
                self.lastRead[.volume] = Date()
                if shouldMute { self.applyMuteToCurrentValue() }
            } catch { self.controls[.volume]?.error = error.localizedDescription }
            self.notify()
        }
    }
    private func applyMuteToCurrentValue() {
        guard let state = controls[.volume], state.value != nil else { return }
        if state.percent > 0 {
            lastVolume[selectedUUID] = state.percent
            UserDefaults.standard.set(state.percent, forKey: "volumeBeforeMute.\(selectedUUID)")
            set(.volume, percent: 0, showHUD: true)
        } else {
            let saved = lastVolume[selectedUUID] ?? UserDefaults.standard.double(forKey: "volumeBeforeMute.\(selectedUUID)")
            set(.volume, percent: saved > 0 ? saved : 30, showHUD: true)
        }
    }
    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval {
                message = L("请在“系统设置 › 通用 › 登录项与扩展”中允许光控。")
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { message = L("无法更改“登录时打开”：%@", error.localizedDescription) }
    }
    func togglePercentage() {
        showPercentage.toggle()
        UserDefaults.standard.set(showPercentage, forKey: "showPercentage")
        notify()
    }
    func diagnostics() -> String {
        let features = Feature.allCases.map { feature in
            let state = controls[feature]
            let value = state?.value.map { "\($0.current)/\($0.maximum)" } ?? "unavailable"
            return "\(feature.rawValue): \(value)\(state?.error.map { " — \($0)" } ?? "")"
        }.joined(separator: "\n")
        let keyboard = keyboardDiagnostics.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        return "MonitorLight \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")\nmacOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\nDisplay: \(selectedDisplay?.name ?? "none")\nBrightness: \(softwareBrightness ? "software" : "hardware")\n\(features)\nHotkeys: \(hotkeyMessage ?? "registered")\nMedia keys: \(mediaKeysEnabled)\n\(keyboard)\nPicture mode: \(displaySettings.currentModeTitle)"
    }
    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics(), forType: .string)
    }
    func recordKeyboardAction(_ action: String) {
        keyboardActionCount += 1
        lastKeyboardAction = action
        notify()
    }
    func updateKeyboardStatus(requested: Bool, enabled: Bool, message: String, diagnostics: [String: Any]) {
        let changed = mediaKeysRequested != requested || mediaKeysEnabled != enabled || mediaKeyMessage != message ||
            !NSDictionary(dictionary: keyboardDiagnostics).isEqual(to: diagnostics)
        guard changed else { return }
        mediaKeysRequested = requested; mediaKeysEnabled = enabled; mediaKeyMessage = message
        keyboardDiagnostics = diagnostics
        notify()
    }
    func changeBrightnessMode(_ mode: BrightnessMode) {
        guard !hasPendingWrites, mode != brightnessMode else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: "brightnessMode.\(selectedUUID)")
        brightnessMode = mode
        discover()
    }
    private func configureBrightness() {
        brightnessMode = UserDefaults.standard.string(forKey: "brightnessMode.\(selectedUUID)").flatMap(BrightnessMode.init) ?? .auto
        softwareBrightness = brightnessMode == .software || (brightnessMode == .auto && controls[.brightness]?.value == nil)
        guard let display = selectedDisplay else { return }
        if softwareBrightness {
            let saved = UserDefaults.standard.object(forKey: "softwareBrightness.\(selectedUUID)") as? Double ?? 100
            if dimming.set(displayID: display.id, percent: saved) {
                controls[.brightness] = ControlState(value: DDCValue(current: Int(saved.rounded()), maximum: 100))
                message = brightnessMode == .auto ? L("显示器未响应硬件亮度，已改用软件调光。") : nil
            } else { message = L("无法找到当前显示器，请重新检测。") }
        } else {
            dimming.remove(displayID: display.id)
            message = ready ? nil : controls[.brightness]?.error
        }
    }
    private func notify() {
        // A mode change can arrive while a probe or user write is pending.
        // Keep its recheck until the operation finishes instead of dropping it.
        if pendingBrightnessRecheck { refresh() }
        onChange?()
        guard writesDiagnostics else { return }
        diagnosticsWrite?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeDiagnostics() }
        diagnosticsWrite = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }
    private func writeDiagnostics() {
        // Local, readable diagnostics also make hardware/UI verification
        // possible without accessibility or recording the user's screen.
        var values: [String: Any] = [:]
        for feature in Feature.allCases {
            let state = controls[feature]
            var entry: [String: Any] = ["writing": state?.isWriting ?? false]
            if let value = state?.value { entry["current"] = value.current; entry["maximum"] = value.maximum }
            if let error = state?.error { entry["error"] = error }
            values[feature.rawValue] = entry
        }
        let snapshot: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "updated": ISO8601DateFormatter().string(from: Date()), "display": selectedDisplay?.name ?? "",
            "brightnessMode": softwareBrightness ? "software" : "hardware", "brightnessPreference": brightnessMode.rawValue, "controls": values,
            "hotkeys": hotkeyMessage ?? "registered", "mediaKeys": mediaKeysEnabled,
            "keyboard": keyboardDiagnostics, "mediaKeysRequested": mediaKeysRequested,
            "displaySettings": displaySettings.diagnostics,
            "keyboardActionCount": keyboardActionCount, "lastKeyboardAction": lastKeyboardAction ?? "none",
            "shades": dimming.diagnostics()]
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MonitorLight")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("status.json"), options: .atomic)
        }
    }
}
