import SwiftUI

struct SettingsPage: View {
    @ObservedObject var model: MonitorModel
    let actions: PanelActions
    let back: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: L("设置"), back: back)

            Module {
                ModuleHeader(title: L("调光方式")) { EmptyView() }
                PillPicker(options: BrightnessMode.allCases.map { ($0, $0.shortTitle) }, selection: model.brightnessMode) {
                    model.changeBrightnessMode($0)
                }
                .disabled(model.hasPendingWrites || model.isLoading)
                Text(model.brightnessMode.explanation)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .animation(Motion.snappy, value: model.brightnessMode)
            }

            Module(padding: 6, spacing: 0) {
                SwitchRow(symbol: "keyboard", tint: .gray, title: L("使用键盘亮度键"),
                          detail: model.mediaKeysRequested && !model.mediaKeysEnabled ? L("需要辅助功能权限") : nil,
                          isOn: model.mediaKeysRequested) { _ in actions.toggleMediaKeys() }
                SwitchRow(symbol: "percent", tint: .blue, title: L("显示百分比"),
                          isOn: model.showPercentage) { _ in model.togglePercentage() }
                SwitchRow(symbol: "power", tint: .green, title: L("登录时打开"),
                          isOn: model.loginEnabled) { _ in model.toggleLogin() }
            }

            Module {
                ModuleHeader(title: L("快捷键")) { Text(L("全局")).font(.system(size: 11)).foregroundStyle(.tertiary) }
                VStack(spacing: 7) {
                    ShortcutRow(title: L("亮度 ±5%"), keys: ["⌃", "⌥", "↑ ↓"])
                    ShortcutRow(title: L("亮度 ±1%"), keys: ["⌃", "⌥", "⇧", "↑ ↓"])
                    ShortcutRow(title: L("音量 ±5%"), keys: ["⌃", "⌥", "← →"])
                    ShortcutRow(title: L("静音 / 恢复"), keys: ["⌃", "⌥", "M"])
                    ShortcutRow(title: L("打开 / 收起面板"), keys: ["⌃", "⌥", "B"])
                }
                Text(L("在面板中可直接用方向键、1–3 和 M 操作；在菜单栏图标上滚动也可调节亮度。"))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                FooterButton(title: copied ? L("已复制") : L("复制诊断"), symbol: copied ? "checkmark" : "doc.on.doc") {
                    model.copyDiagnostics()
                    withAnimation(Motion.snappy) { copied = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { withAnimation(Motion.snappy) { copied = false } }
                }
                FooterButton(title: L("检测显示器"), symbol: "arrow.clockwise") { model.discover() }
                    .disabled(model.isLoading)
                FooterButton(title: L("退出"), symbol: "power", role: .destructive, action: actions.quit)
            }
            Text(L("光控 %@ · 本地运行，不联网", Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("开发版")))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }
}

extension BrightnessMode {
    var shortTitle: String {
        switch self { case .auto: return L("自动"); case .hardware: return L("硬件"); case .software: return L("软件") }
    }
    var explanation: String {
        switch self {
        case .auto: return L("优先调节显示器背光；显示器不接受时自动改用软件遮罩。")
        case .hardware: return L("仅通过 DDC/CI 调节背光；失败时给出提示，不改用遮罩。")
        case .software: return L("用半透明遮罩调暗画面，背光亮度不变；截图和录屏中可能看到遮罩。")
        }
    }
}

private struct SwitchRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var detail: String?
    let isOn: Bool
    let onChange: (Bool) -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .medium))
                if let detail { Text(detail).font(.system(size: 10)).foregroundStyle(.orange) }
            }
            Spacer(minLength: 6)
            Toggle(title, isOn: Binding(get: { isOn }, set: onChange))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
    }
}

private struct ShortcutRow: View {
    let title: String
    let keys: [String]
    var body: some View {
        HStack(spacing: 3) {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            ForEach(keys, id: \.self) { Keycap(key: $0) }
        }
    }
}

private struct FooterButton: View {
    let title: String
    let symbol: String
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(role: role, action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(height: 16)
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
            }
            .foregroundStyle(role == .destructive && hovering ? Color.red : Color.primary.opacity(0.8))
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.055)))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
    }
}
