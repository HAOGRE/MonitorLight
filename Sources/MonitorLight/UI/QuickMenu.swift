import AppKit

/// Right-click menu on the status item: one-step actions without the panel.
final class QuickMenu: NSObject {
    private let model: MonitorModel
    private let openSettings: () -> Void

    init(model: MonitorModel, openSettings: @escaping () -> Void) {
        self.model = model
        self.openSettings = openSettings
    }

    func make() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = model.controls[.brightness]?.value.map { Int($0.percent.rounded()) }
        for (index, preset) in PanelView.presets.enumerated() {
            let item = NSMenuItem(title: "\(preset.title)  \(Int(preset.value))%", action: #selector(applyPreset(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = []
            item.tag = Int(preset.value)
            item.image = NSImage(systemSymbolName: preset.symbol, accessibilityDescription: nil)
            item.state = current == Int(preset.value) ? .on : .off
            item.target = self
            item.isEnabled = model.ready
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let volumeAvailable = model.controls[.volume]?.value != nil
        let muted = volumeAvailable && model.controls[.volume]?.percent == 0
        let mute = NSMenuItem(title: muted ? L("恢复音量") : L("静音"), action: #selector(toggleMute), keyEquivalent: "m")
        mute.keyEquivalentModifierMask = []
        mute.image = NSImage(systemSymbolName: muted ? "speaker.wave.2.fill" : "speaker.slash.fill", accessibilityDescription: nil)
        mute.target = self
        mute.isEnabled = volumeAvailable
        menu.addItem(mute)
        menu.addItem(.separator())
        let percentage = NSMenuItem(title: L("显示百分比"), action: #selector(togglePercentage), keyEquivalent: "")
        percentage.state = model.showPercentage ? .on : .off
        percentage.target = self
        menu.addItem(percentage)
        let settings = NSMenuItem(title: L("设置…"), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem(title: L("退出光控"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    @objc private func applyPreset(_ sender: NSMenuItem) { model.set(.brightness, percent: Double(sender.tag), showHUD: true) }
    @objc private func toggleMute() { model.toggleMute() }
    @objc private func togglePercentage() { model.togglePercentage() }
    @objc private func showSettings() { openSettings() }
}
