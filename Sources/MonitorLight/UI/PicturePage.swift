import SwiftUI

/// Model-specific picture controls (BenQ EW3270U).
struct PicturePage: View {
    @ObservedObject var model: DisplaySettingsModel
    let back: () -> Void
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                PageHeader(title: L("画面"), back: back)
                if model.isLoading || model.isWriting { ProgressView().controlSize(.small).transition(.opacity) }
            }
            Module {
                ModuleHeader(title: L("图像模式")) { EmptyView() }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(model.pictureModeChoices) { mode in
                        Tile(title: mode.id == "lowblue" ? L("低蓝光") : mode.localizedTitle.replacingOccurrences(of: " / Rec.709", with: ""),
                             symbol: Self.symbol(mode.id), selected: model.currentPictureModeID == mode.id) {
                            model.selectPictureMode(id: mode.id)
                        }
                        .help(mode.id == "srgb" ? L("sRGB 与 Rec.709 在此显示器上为同一模式，无法分别选择") : mode.localizedTitle)
                    }
                }
            }
            .disabled(model.values["picture-mode"] == nil)

            Module {
                ModuleHeader(title: L("低蓝光")) { EmptyView() }
                HStack(spacing: 6) {
                    ForEach(DisplaySettingsModel.lowBlueScenes) { scene in
                        Tile(title: scene.shortTitle, symbol: Self.symbol(scene.id),
                             selected: model.currentModeValue == scene.value, compact: true) {
                            model.set("picture-mode", value: scene.value)
                        }
                    }
                }
            }
            .disabled(model.values["picture-mode"] == nil)
            .help(L("切换低蓝光场景会同时切换图像模式"))

            Module {
                if let sharpness = model.values["sharpness"] {
                    row(L("锐利度")) { Stepper(value: sharpness.current, range: 1...10) { model.set("sharpness", value: $0) } }
                }
                if model.values["response-time"] != nil {
                    row("AMA") {
                        PillPicker(options: [(0, L("关")), (1, L("高")), (2, L("高级"))],
                                   selection: model.values["response-time"]?.current) { model.set("response-time", value: $0) }
                            .frame(width: 176)
                    }
                    .help(L("动态画面建议选“高”；“高级”可能产生过冲残影"))
                }
                if model.values["aspect-ratio"] != nil {
                    row(L("显示比例")) {
                        PillPicker(options: [(2, L("全屏")), (5, L("按比例")), (1, "1:1")],
                                   selection: model.values["aspect-ratio"]?.current) { model.set("aspect-ratio", value: $0) }
                            .frame(width: 176)
                    }
                }
                if model.values.isEmpty {
                    Text(L("正在读取…")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }

            if let error = model.error { InlineError(text: error).padding(.horizontal, 4) }
            Text(L("HDR、影院 HDR 和 B.I.+ 请在显示器菜单中调整。"))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
        }
        .disabled(model.isWriting)
    }

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 8)
            content()
        }
    }
    static func symbol(_ id: String) -> String {
        switch id {
        case "standard": return "display"
        case "lowblue": return "eye.fill"
        case "game": return "gamecontroller.fill"
        case "photo": return "photo.fill"
        case "srgb": return "paintpalette.fill"
        case "eco": return "leaf.fill"
        case "mbook": return "macbook"
        case "user": return "slider.horizontal.3"
        case "multimedia": return "play.rectangle.fill"
        case "web": return "globe"
        case "office": return "briefcase.fill"
        case "reading": return "book.fill"
        default: return "circle"
        }
    }
}

/// Compact − value + control.
private struct Stepper: View {
    let value: Int
    let range: ClosedRange<Int>
    let onChange: (Int) -> Void
    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "minus", help: L("降低锐利度"), size: 24) { onChange(value - 1) }
                .disabled(value <= range.lowerBound)
            Text("\(value)")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .animation(Motion.snappy, value: value)
                .frame(width: 26)
            IconButton(symbol: "plus", help: L("提高锐利度"), size: 24) { onChange(value + 1) }
                .disabled(value >= range.upperBound)
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
    }
}
