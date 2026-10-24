import SwiftUI

struct PanelActions {
    var toggleMediaKeys: () -> Void = {}
    var reconnectMediaKeys: () -> Void = {}
    var quit: () -> Void = {}
}

/// Root of the glass panel: a compact main page with drill-in pages for
/// picture settings and preferences.
struct PanelView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: PanelState
    var actions = PanelActions()
    var onHeight: (CGFloat) -> Void = { _ in }

    static let presets: [(title: String, value: Double, symbol: String)] = [
        (L("柔和"), 35, "moon.fill"), (L("日常"), 60, "cup.and.saucer.fill"), (L("明亮"), 85, "sun.max.fill")
    ]

    var body: some View {
        ZStack(alignment: .top) {
            switch state.page {
            case .main:
                MainPage(model: model, state: state, actions: actions)
                    .transition(pageTransition(forward: false))
            case .picture:
                PicturePage(model: model.displaySettings) { state.go(.main) }
                    .transition(pageTransition(forward: true))
            case .settings:
                SettingsPage(model: model, actions: actions) { state.go(.main) }
                    .transition(pageTransition(forward: true))
            }
        }
        .padding(14)
        .frame(width: 296)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { Color.clear.preference(key: HeightKey.self, value: $0.size.height) })
        .onPreferenceChange(HeightKey.self) { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
    }
    private func pageTransition(forward: Bool) -> AnyTransition {
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                           removal: .move(edge: forward ? .trailing : .leading).combined(with: .opacity))
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Main page

struct MainPage: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: PanelState
    let actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if model.isLoading && model.controls.isEmpty {
                skeleton
            } else if model.selectedDisplay == nil || (!model.ready && model.controls.isEmpty) {
                EmptyState(message: model.message) { model.discover() }
            } else {
                if let notice { NoticeBanner(text: notice) }
                brightnessModule
                volumeModule
                InputSourceModule(model: model.displaySettings)
                if model.displaySettings.supported { pictureRow }
                if model.mediaKeysRequested && !model.mediaKeysEnabled { mediaKeyBanner }
                footer
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.accentColor.gradient)
                Image(systemName: "display").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)
            .shadow(color: Color.accentColor.opacity(0.35), radius: 4, y: 2)
            VStack(alignment: .leading, spacing: 1) {
                displayTitle
                HStack(spacing: 5) {
                    StatusDot(color: statusColor, pulsing: model.isLoading || model.hasPendingWrites)
                    Text(statusLine).font(.system(size: 11)).foregroundStyle(.secondary)
                        .contentTransition(.opacity).animation(Motion.snappy, value: statusLine)
                }
            }
            Spacer(minLength: 0)
            IconButton(symbol: "gearshape.fill", help: L("设置（⌘,）")) { state.go(.settings) }
        }
    }
    @ViewBuilder private var displayTitle: some View {
        let title = Text(model.selectedDisplay?.displayName ?? L("光控")).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        if model.displays.count > 1 {
            Menu {
                ForEach(model.displays) { display in
                    Toggle(display.displayName, isOn: Binding(get: { display.uuid == model.selectedUUID },
                                                       set: { if $0 { model.select(display.uuid) } }))
                }
            } label: {
                HStack(spacing: 3) { title; Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary) }
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        } else {
            title
        }
    }
    private var statusLine: String {
        if model.isLoading { return L("正在连接…") }
        if model.hasPendingWrites { return L("正在应用…") }
        guard model.ready else { return L("未连接") }
        var parts = [model.softwareBrightness ? L("软件调光") : "DDC"]
        if model.displaySettings.supported, model.displaySettings.values["picture-mode"] != nil {
            parts.append(model.displaySettings.currentModeTitle)
        }
        return parts.joined(separator: " · ")
    }
    private var statusColor: Color {
        if model.isLoading { return .secondary }
        if !model.ready { return .orange }
        return model.softwareBrightness ? .yellow : .green
    }

    // MARK: Modules

    private var brightnessModule: some View {
        let state = model.controls[.brightness] ?? ControlState()
        let available = state.value != nil && !model.isLoading
        return Module {
            ModuleHeader(title: L("亮度"), badge: model.softwareBrightness ? L("软件") : nil) {
                PercentText(value: state.value == nil ? nil : state.percent)
            }
            .help(model.softwareBrightness ? L("显示器已锁定硬件亮度（通常由 B.I.+ 自动亮度、HDR 或当前图像模式导致），现以遮罩调暗画面。在显示器上关闭相应功能后，会自动恢复硬件调光。") : "")
            GlassSlider(value: state.percent, symbol: state.percent < 40 ? "sun.min.fill" : "sun.max.fill",
                        label: L("亮度"), enabled: available, detents: PanelView.presets.map(\.value)) {
                model.set(.brightness, percent: $0)
            }
            HStack(spacing: 6) {
                ForEach(Array(PanelView.presets.enumerated()), id: \.offset) { index, preset in
                    Chip(title: preset.title, symbol: preset.symbol,
                         selected: state.value != nil && abs(state.percent - preset.value) < 0.5) {
                        model.set(.brightness, percent: preset.value)
                    }
                    .help(L("亮度 %d%%（按 %d）", Int(preset.value), index + 1))
                }
            }
            .disabled(!available)
            if let error = state.error, state.value != nil { InlineError(text: error) }
        }
    }
    private var volumeModule: some View {
        let state = model.controls[.volume] ?? ControlState()
        let available = state.value != nil && !model.isLoading
        let muted = state.value != nil && state.percent == 0
        return Module {
            ModuleHeader(title: L("音量")) {
                PercentText(value: state.value == nil ? nil : state.percent)
            }
            HStack(spacing: 8) {
                GlassSlider(value: state.percent, symbol: muted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                            variableValue: muted ? nil : state.percent / 100, label: L("显示器音量"), enabled: available) {
                    model.set(.volume, percent: $0)
                }
                IconButton(symbol: muted ? "speaker.slash.fill" : "speaker.fill",
                           help: muted ? L("恢复音量（M）") : L("静音（M）"), size: 30, active: muted, plated: true) { model.toggleMute() }
                    .disabled(!available)
            }
            if let error = state.error, state.value != nil { InlineError(text: error) }
        }
    }
    private var pictureRow: some View {
        let settings = model.displaySettings
        // Low blue scenes show as an eye + scene name, which stays short in every language.
        let lowBlue = settings.currentMode?.isLowBlueLight == true
        return NavigationRow(symbol: "paintpalette.fill", tint: .purple, title: L("画面"),
                             detail: settings.values["picture-mode"] == nil ? "—"
                                : lowBlue ? settings.currentMode!.shortTitle : settings.currentModeTitle,
                             detailSymbol: lowBlue ? "eye.fill" : nil) {
            state.go(.picture)
        }
        .disabled(!model.ready || model.isLoading)
    }
    private var footer: some View {
        HStack(spacing: 10) {
            KeyHint(keys: ["↑↓"], title: L("亮度"))
            KeyHint(keys: ["←→"], title: L("音量"))
            KeyHint(keys: ["1–3"], title: L("预设"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 1)
    }

    // MARK: States

    private var notice: String? {
        if let hotkey = model.hotkeyMessage { return hotkey }
        guard !model.isLoading else { return nil }
        // The automatic software fallback is already shown by the badge and status line.
        if model.ready && model.softwareBrightness && model.brightnessMode == .auto { return nil }
        return model.message
    }
    private var mediaKeyBanner: some View {
        NoticeBanner(text: L("使用键盘亮度键需要辅助功能权限"), symbol: "keyboard", tint: .accentColor,
                     actionTitle: L("前往设置"), action: actions.reconnectMediaKeys)
    }
    private var skeleton: some View {
        VStack(spacing: 10) {
            ForEach(0..<2, id: \.self) { _ in
                Module {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)).frame(width: 60, height: 12)
                    Capsule().fill(Color.primary.opacity(0.08)).frame(height: 30)
                }
            }
        }
        .modifier(Shimmer())
    }
}

// Observe the input state directly so reads and writes update the menu without
// waiting for an unrelated brightness/volume publication from MonitorModel.
struct InputSourceModule: View {
    @ObservedObject var model: DisplaySettingsModel

    var body: some View {
        let settings = model
        let selected = settings.currentInputSource
        if settings.supported && settings.values["input-source"] != nil {
            Module {
                HStack(spacing: 8) {
                    ModuleHeader(title: L("信号源")) { }
                    Spacer(minLength: 0)
                    Menu {
                        ForEach(DisplaySettingsModel.inputSources) { source in
                            Button {
                                settings.selectInputSource(value: source.value)
                            } label: {
                                if selected?.value == source.value {
                                    Label(source.title, systemImage: "checkmark")
                                } else {
                                    Text(source.title)
                                }
                            }
                            .disabled(settings.isWriting)
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(selected?.title ?? L("未知信号源"))
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(L("信号源"))
                    .disabled(settings.isWriting)
                }
                if let error = settings.error { InlineError(text: error) }
            }
        }
    }
}

// MARK: - Pieces

struct StatusDot: View {
    let color: Color
    var pulsing = false
    @State private var phase = false
    var body: some View {
        Circle().fill(color).frame(width: 6, height: 6)
            .overlay(Circle().stroke(color.opacity(0.5), lineWidth: 1).scaleEffect(phase ? 2.2 : 1).opacity(phase ? 0 : 0.8))
            .onAppear { animate() }
            .onChange(of: pulsing) { _, _ in animate() }
    }
    private func animate() {
        guard pulsing, !Motion.reduced else { phase = false; return }
        phase = false
        withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = true }
    }
}

struct NavigationRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var detailSymbol: String?
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(tint.gradient))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                HStack(spacing: 4) {
                    if let detailSymbol { Image(systemName: detailSymbol).font(.system(size: 10, weight: .semibold)) }
                    Text(detail).lineLimit(1)
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).foregroundStyle(.tertiary)
                    .offset(x: hovering && !Motion.reduced ? 2 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.09 : 0.055)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .accessibilityLabel("\(title)，\(detail)")
    }
}

struct NoticeBanner: View {
    let text: String
    var symbol = "exclamationmark.triangle.fill"
    var tint: Color = .orange
    var actionTitle: String?
    var action: (() -> Void)?
    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(tint.gradient))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.12)))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

struct InlineError: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle.fill")
            .font(.system(size: 10)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct EmptyState: View {
    let message: String?
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
                .symbolRenderingMode(.hierarchical)
                .padding(.top, 8)
            Text(L("未检测到外接显示器")).font(.system(size: 13, weight: .semibold))
            Text(message ?? L("请确认显示器已开启，并在显示器菜单中打开 DDC/CI。"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button(action: retry) {
                Label(L("检测显示器"), systemImage: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(Color.accentColor.gradient))
            }
            .buttonStyle(PressStyle())
            .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.055)))
    }
}

/// Soft breathing placeholder while the display is read.
struct Shimmer: ViewModifier {
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                guard !Motion.reduced else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever()) { dim = true }
            }
    }
}
