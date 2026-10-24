import Foundation

/// Optional local automation entry point for macOS Shortcuts and scripts.
enum ControlCommand: Equatable {
    case brightness(Double), volume(Double), adjustBrightness(Double), mute, show
    init?(url: URL) {
        guard url.scheme == "monitorlight" else { return nil }
        let value = Double(url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        switch url.host {
        case "brightness":
            guard let value, value.isFinite, (0...100).contains(value) else { return nil }
            self = .brightness(value)
        case "volume":
            guard let value, value.isFinite, (0...100).contains(value) else { return nil }
            self = .volume(value)
        case "adjust-brightness":
            guard let value, value.isFinite, (-100...100).contains(value) else { return nil }
            self = .adjustBrightness(value)
        case "mute": self = .mute
        case "show": self = .show
        default: return nil
        }
    }
    func apply(to model: MonitorModel) {
        switch self {
        case .brightness(let value): model.set(.brightness, percent: value, showHUD: true)
        case .volume(let value): model.set(.volume, percent: value, showHUD: true)
        case .adjustBrightness(let step): model.adjust(.brightness, by: step)
        case .mute: model.toggleMute()
        case .show: break
        }
    }
}
