import Foundation
import SwiftUI

struct PictureMode: Identifiable, Equatable {
    let id: String
    let title: String
    let value: Int
    /// `title` is a localization key; these return display text.
    var localizedTitle: String { L(title) }
    /// Scene name without the "Low Blue Light · " prefix.
    var shortTitle: String { L(title.components(separatedBy: " · ").last ?? title) }
    var isLowBlueLight: Bool { ["multimedia", "web", "office", "reading"].contains(id) }
}

struct InputSource: Identifiable {
    let value: Int
    let title: String
    var id: Int { value }
}

/// Model-specific controls. Only confirmed readbacks replace visible state.
final class DisplaySettingsModel: ObservableObject {
    @Published private(set) var values: [String: DDCValue] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isWriting = false
    @Published private(set) var error: String?
    @Published private(set) var modes: [PictureMode] = []
    @Published private(set) var supported = false
    var onChange: (() -> Void)?
    var onModeChanged: (() -> Void)?
    private let client: DDCProviding
    private var uuid = ""
    private var generation = 0
    private var revision = 0
    private var lastLowBlueValue = 0x213
    private var observedPictureMode: Int?

    // Titles are localization keys (see PictureMode.localizedTitle).
    static let knownModes: [PictureMode] = [
        .init(id: "standard", title: "标准", value: 0), // i18n-key
        .init(id: "multimedia", title: "低蓝光 · 多媒体", value: 0x113), // i18n-key
        .init(id: "web", title: "低蓝光 · 网上冲浪", value: 0x213), // i18n-key
        .init(id: "office", title: "低蓝光 · 办公室", value: 0x313), // i18n-key
        .init(id: "reading", title: "低蓝光 · 阅读", value: 0x413), // i18n-key
        .init(id: "game", title: "游戏", value: 5), // i18n-key
        .init(id: "photo", title: "照片", value: 11), // i18n-key
        .init(id: "srgb", title: "sRGB / Rec.709", value: 12), // i18n-key
        .init(id: "eco", title: "省电", value: 14), // i18n-key
        .init(id: "mbook", title: "M-book", value: 15), // i18n-key
        .init(id: "user", title: "用户", value: 18) // i18n-key
    ]
    var currentMode: PictureMode? { modes.first { $0.value == values["picture-mode"]?.current } }
    static var lowBlueScenes: [PictureMode] { knownModes.filter(\.isLowBlueLight) }
    static let inputSources: [InputSource] = [
        // EW3270U's physical DP connector reports 0x10, not MCCS DP-1 (0x0f).
        .init(value: 0x10, title: "DisplayPort"),
        .init(value: 0x0f, title: "USB-C"),
        .init(value: 0x11, title: "HDMI 1"),
        .init(value: 0x12, title: "HDMI 2")
    ]
    var currentInputSource: InputSource? {
        Self.inputSources.first { $0.value == values["input-source"]?.current }
    }
    var pictureModeChoices: [PictureMode] {
        var choices = modes.filter { !$0.isLowBlueLight }
        choices.insert(.init(id: "lowblue", title: "低蓝光", value: lastLowBlueValue), at: min(1, choices.count)) // i18n-key
        return choices
    }
    var currentPictureModeID: String {
        guard let mode = currentMode else { return "unknown" }
        return mode.isLowBlueLight ? "lowblue" : mode.id
    }
    var currentModeTitle: String { currentMode?.localizedTitle ?? (currentModeValue == 255 ? L("HDR 或显示器专用模式") : L("未识别的模式")) }
    var currentModeValue: Int { values["picture-mode"]?.current ?? -1 }
    var diagnostics: [String: Any] {
        ["values": values.mapValues { ["current": $0.current, "maximum": $0.maximum] },
         "writing": isWriting, "mode": currentModeTitle, "error": error ?? ""]
    }

    init(client: DDCProviding) { self.client = client }

    func configure(display: DisplayInfo?) {
        let next = display?.uuid ?? ""
        if uuid != next {
            generation += 1; revision = 0
            uuid = next; values = [:]; isLoading = false; isWriting = false; error = nil
            observedPictureMode = nil
        }
        supported = display?.name == "BenQ EW3270U"
        loadModes()
        refresh()
    }
    private func loadModes() {
        modes = Self.knownModes
        let saved = UserDefaults.standard.integer(forKey: "lowBlueScene.\(uuid)")
        lastLowBlueValue = Self.lowBlueScenes.contains { $0.value == saved } ? saved : 0x213
    }
    func selectPictureMode(id: String) {
        guard let mode = pictureModeChoices.first(where: { $0.id == id }) else { return }
        set("picture-mode", value: mode.value)
    }
    func selectInputSource(value: Int) {
        guard Self.inputSources.contains(where: { $0.value == value }) else { return }
        set("input-source", value: value)
    }
    private func rememberLowBlueScene() {
        guard let mode = currentMode, mode.isLowBlueLight, !uuid.isEmpty else { return }
        lastLowBlueValue = mode.value
        UserDefaults.standard.set(mode.value, forKey: "lowBlueScene.\(uuid)")
    }
    func refresh() {
        guard supported, !uuid.isEmpty, !isLoading, !isWriting else { return }
        isLoading = true
        let token = generation, readRevision = revision
        client.perform(["settings", uuid]) { [weak self] result in
            guard let self, token == self.generation else { return }
            self.isLoading = false
            guard self.revision == readRevision else { return }
            do {
                let data = try result.get()
                let json = try JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] ?? [:]
                self.values = json.compactMapValues { entry in
                    guard let current = entry["current"] as? Int, let maximum = entry["maximum"] as? Int,
                          maximum > 0, current >= 0, current <= maximum else { return nil }
                    return DDCValue(current: current, maximum: maximum)
                }
                self.rememberLowBlueScene()
                if let mode = self.values["picture-mode"]?.current {
                    let changed = self.observedPictureMode != nil && self.observedPictureMode != mode
                    self.observedPictureMode = mode
                    if changed { self.onModeChanged?() }
                }
            } catch { self.error = error.localizedDescription }
            self.onChange?()
        }
    }
    func set(_ feature: String, value: Int) {
        // An explicit source choice takes precedence over an older background
        // read. Its revision prevents that read from overwriting the choice.
        guard !isWriting, (!isLoading || feature == "input-source"),
              let old = values[feature], old.current != value else { return }
        isWriting = true; error = nil; revision += 1
        onChange?()
        let token = generation
        client.perform(["set", uuid, feature, String(value)]) { [weak self] result in
            guard let self, token == self.generation else { return }
            self.isWriting = false
            do {
                let confirmed = try JSONDecoder().decode(DDCValue.self, from: result.get())
                guard confirmed.current == value else { throw DDCFailure(message: L("显示器未确认此设置。")) }
                self.values[feature] = confirmed
                if feature == "picture-mode" {
                    self.observedPictureMode = confirmed.current
                    self.rememberLowBlueScene()
                    self.onModeChanged?()
                }
            } catch { self.error = error.localizedDescription }
            self.onChange?()
            self.refresh()
        }
    }
}
