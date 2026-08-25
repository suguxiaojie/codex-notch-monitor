import SwiftUI

/// QuotaView-inspired settings surface: native two-column hierarchy outside,
/// restrained row groups inside, and the real live island as the preview.
struct QuotaStyleSettingsView: View {
    @ObservedObject var store: MonitorStore
    @AppStorage(ActivityIslandPreferenceKey.enabled) private var islandEnabled = true
    @AppStorage(ActivityIslandPreferenceKey.mode) private var modeRawValue = ActivityIslandMode.floating.rawValue
    @AppStorage(ActivityIslandPreferenceKey.menuBarDensity) private var menuBarDensityRawValue = MenuBarInformationDensity.automatic.rawValue
    @AppStorage(ActivityIslandPreferenceKey.screen) private var screenRawValue = ActivityIslandScreenMode.automatic.rawValue
    @AppStorage(ActivityIslandPreferenceKey.position) private var positionRawValue = ActivityIslandPosition.center.rawValue
    @AppStorage(ActivityIslandPreferenceKey.visualStyle) private var visualStyleRawValue = ActivityIslandVisualStyle.rippleGlow.rawValue
    @AppStorage(ActivityIslandPreferenceKey.surfaceOpacity) private var surfaceOpacity = 0.38
    @AppStorage(ActivityIslandPreferenceKey.surfaceScale) private var surfaceScale = 1.00
    @AppStorage(ActivityIslandPreferenceKey.expandedHold) private var expandedHold = 8.0
    @AppStorage(ActivityIslandPreferenceKey.compactHide) private var compactHide = 120.0
    @AppStorage(ActivityIslandPreferenceKey.reduceMotion) private var reduceMotion = false
    @AppStorage(ActivityIslandPreferenceKey.showCompletion) private var showCompletion = true
    @State private var isAdjustingSlider = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 18) {
                livePreview

                settingsGroup("显示") {
                    preferenceRow(
                        title: "显示灵动岛",
                        detail: "关闭后仍保留菜单栏与本地额度监控。"
                    ) {
                        Toggle("", isOn: $islandEnabled).labelsHidden()
                    }

                    groupDivider

                    preferenceRow(
                        title: "显示方式",
                        detail: displayModeDetail
                    ) {
                        Picker("", selection: $modeRawValue) {
                            ForEach(ActivityIslandMode.allCases) { mode in
                                Text(mode.title).tag(mode.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 285)
                    }

                    if selectedMode == .floating {
                        groupDivider

                        preferenceRow(
                            title: "显示器与位置",
                            detail: "用于独立浮动状态岛。"
                        ) {
                            HStack(spacing: 8) {
                                Picker("显示器", selection: $screenRawValue) {
                                    ForEach(ActivityIslandScreenMode.allCases) { screen in
                                        Text(screen.title).tag(screen.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 90)

                                Picker("位置", selection: $positionRawValue) {
                                    ForEach(ActivityIslandPosition.allCases) { position in
                                        Text(position.title).tag(position.rawValue)
                                    }
                                }
                                .labelsHidden()
                                .pickerStyle(.segmented)
                                .frame(width: 158)
                            }
                        }
                    }

                    if selectedMode == .menuBar {
                        groupDivider

                        preferenceRow(
                            title: "菜单栏信息密度",
                            detail: "自动模式会在空间不足时逐级收短。"
                        ) {
                            Picker("", selection: $menuBarDensityRawValue) {
                                ForEach(MenuBarInformationDensity.allCases) { density in
                                    Text(density.title).tag(density.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(width: 285)
                        }
                    }

                    groupDivider

                    opacitySliderRow

                    groupDivider

                    scaleSliderRow
                }

                settingsGroup("灵动岛动画") {
                    Text("选择任务状态使用的光球动画。")
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)

                    HStack(spacing: 12) {
                        ForEach(ActivityIslandVisualStyle.allCases) { style in
                            visualStyleButton(style)
                        }
                    }
                    .padding(.top, 3)
                }

                settingsGroup("时间") {
                    sliderRow(
                        title: "完成后缩小",
                        detail: "任务完成后保持展开状态的时间。",
                        value: $expandedHold,
                        range: 5...60
                    )

                    groupDivider

                    sliderRow(
                        title: "缩小后隐藏",
                        detail: "进入紧凑态后继续显示的时间。",
                        value: $compactHide,
                        range: 5...120
                    )

                    groupDivider

                    preferenceRow(
                        title: "显示任务完成反馈",
                        detail: "先显示完成状态，再收紧并隐藏。"
                    ) {
                        Toggle("", isOn: $showCompletion).labelsHidden()
                    }
                }

                settingsGroup("辅助功能") {
                    preferenceRow(
                        title: "减少动态效果",
                        detail: "停止持续流场与弹性过渡；macOS 系统设置同样生效。"
                    ) {
                        Toggle("", isOn: $reduceMotion).labelsHidden()
                    }
                }
            }
            .padding(.bottom, 10)
        }
        .scrollDisabled(isAdjustingSlider)
        .onDisappear { isAdjustingSlider = false }
        .onChange(of: islandEnabled) { _ in notifyPreferenceChange() }
        .onChange(of: modeRawValue) { _ in notifyPreferenceChange() }
        .onChange(of: menuBarDensityRawValue) { _ in notifyPreferenceChange() }
        .onChange(of: screenRawValue) { _ in notifyPreferenceChange() }
        .onChange(of: positionRawValue) { _ in notifyPreferenceChange() }
        .onChange(of: visualStyleRawValue) { _ in notifyPreferenceChange() }
        .onChange(of: surfaceOpacity) { _ in notifyPreferenceChange() }
        .onChange(of: surfaceScale) { _ in notifyPreferenceChange() }
        .onChange(of: expandedHold) { _ in notifyPreferenceChange() }
        .onChange(of: compactHide) { _ in notifyPreferenceChange() }
        .onChange(of: reduceMotion) { _ in notifyPreferenceChange() }
        .onChange(of: showCompletion) { _ in notifyPreferenceChange() }
    }

    private var livePreview: some View {
        let phase = store.focusedProject?.task.phase ?? .working
        let snapshot = ActivityIslandSnapshot(
            projectID: store.focusedProject?.id ?? "preview",
            projectName: store.focusedProject?.name ?? "Codex Monitor",
            phase: phase,
            actionText: store.focusedProject?.detailedActionSummary ?? "正在处理当前任务",
            sessionCount: store.focusedProject?.sessionCount ?? 1,
            projectCount: max(1, store.activeProjects.count),
            updatedAt: Date()
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("灵动岛预览")
                        .font(MonitorTypography.cardTitle)
                    Text("使用当前任务状态，设置会立即生效。")
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer()
                Text(previewStatusTitle)
                    .font(MonitorTypography.control)
                    .foregroundStyle(islandEnabled ? Color.green : Color.gray)
            }

            if islandEnabled && selectedMode == .floating {
                ActivityIslandPreview(
                    snapshot: snapshot,
                    style: selectedVisualStyle,
                    animated: !reduceMotion,
                    surfaceOpacity: surfaceOpacity,
                    surfaceScale: CGFloat(surfaceScale)
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .frame(
                    height: ActivityIslandLayout.maximumSettingsPreviewHeight,
                    alignment: .center
                )
            } else {
                HStack(spacing: 9) {
                    Image(systemName: islandEnabled ? "menubar.rectangle" : "eye.slash")
                        .font(.system(size: 14, weight: .semibold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(islandEnabled ? "浮动灵动岛已隐藏" : "灵动岛已关闭")
                            .font(MonitorTypography.cardTitle)
                        Text(
                            islandEnabled
                                ? "实时任务状态会直接显示在顶部菜单栏。"
                                : "菜单栏额度与本地监控仍会继续运行。"
                        )
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(
                    Color.black.opacity(0.20),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                }
            }
        }
    }

    private func settingsGroup<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(MonitorTypography.cardTitle)
                .foregroundStyle(MonitorTheme.secondaryText)
            content()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(MonitorTheme.cardFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 0.7)
        }
    }

    private func preferenceRow<Trailing: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(MonitorTypography.cardTitle)
                    .foregroundStyle(MonitorTheme.primaryText)
                Text(detail)
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 18)
            trailing()
        }
        .frame(minHeight: MonitorGeometry.settingsRowHeight)
    }

    private func visualStyleButton(_ style: ActivityIslandVisualStyle) -> some View {
        let selected = selectedVisualStyle == style
        return Button {
            visualStyleRawValue = style.rawValue
        } label: {
            VStack(spacing: 8) {
                ActivityStateOrb(
                    style: style,
                    phase: store.focusedProject?.task.phase ?? .working,
                    animated: islandEnabled && !reduceMotion
                )
                .frame(width: 54, height: 54)

                Text(style.title)
                    .font(MonitorTypography.rowTitle)
                    .foregroundStyle(selected ? .white : MonitorTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, minHeight: 103)
            .background(
                selected ? MonitorTheme.selection.opacity(0.25) : Color.white.opacity(0.018),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected ? Color(red: 0.38, green: 0.48, blue: 1.00) : Color.white.opacity(0.06),
                        lineWidth: selected ? 1.1 : 0.7
                    )
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sliderRow(
        title: String,
        detail: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(MonitorTypography.cardTitle)
                    Text(detail)
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer()
                Text("\(Int(value.wrappedValue)) 秒")
                    .font(MonitorTypography.rowTitle)
                    .foregroundStyle(MonitorTheme.primaryText)
                    .monospacedDigit()
            }
            Slider(
                value: value,
                in: range,
                step: 1,
                onEditingChanged: setSliderEditing
            )
                .tint(MonitorTheme.selection)
        }
        .padding(.vertical, 2)
    }

    private var opacitySliderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("灵动岛透明度")
                        .font(MonitorTypography.cardTitle)
                    Text("数值越低越透明；只调整黑色背景，不增加磨砂。")
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer()
                Text("\(Int((surfaceOpacity * 100).rounded()))%")
                    .font(MonitorTypography.rowTitle)
                    .foregroundStyle(MonitorTheme.primaryText)
                    .monospacedDigit()
            }
            Slider(
                value: $surfaceOpacity,
                in: 0.10...0.90,
                step: 0.01,
                onEditingChanged: setSliderEditing
            )
                .tint(MonitorTheme.selection)
                .accessibilityLabel("灵动岛透明度")
                .accessibilityValue("\(Int((surfaceOpacity * 100).rounded()))%")
        }
        .padding(.vertical, 2)
    }

    private var scaleSliderRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("灵动岛缩放")
                        .font(MonitorTypography.cardTitle)
                    Text("等比调整窗口、内容、光球、圆角和阴影。")
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer()
                Text("\(Int((surfaceScale * 100).rounded()))%")
                    .font(MonitorTypography.rowTitle)
                    .foregroundStyle(MonitorTheme.primaryText)
                    .monospacedDigit()
            }
            Slider(
                value: $surfaceScale,
                in: 0.25...1.25,
                step: 0.01,
                onEditingChanged: setSliderEditing
            )
                .tint(MonitorTheme.selection)
                .accessibilityLabel("灵动岛缩放")
                .accessibilityValue("\(Int((surfaceScale * 100).rounded()))%")
        }
        .padding(.vertical, 2)
    }

    private var groupDivider: some View {
        Divider().overlay(MonitorTheme.separator)
    }

    private var selectedMode: ActivityIslandMode {
        ActivityIslandMode(rawValue: modeRawValue) ?? .floating
    }

    private var selectedVisualStyle: ActivityIslandVisualStyle {
        ActivityIslandVisualStyle(rawValue: visualStyleRawValue) ?? .rippleGlow
    }

    private var displayModeDetail: String {
        switch selectedMode {
        case .floating:
            return "独立显示实时任务灵动岛，同时保留菜单栏额度。"
        case .menuBar:
            return "隐藏浮动灵动岛，把实时任务状态收进菜单栏。"
        }
    }

    private var previewStatusTitle: String {
        guard islandEnabled else { return "已关闭" }
        return selectedMode == .floating ? "浮动显示" : "仅菜单栏"
    }

    private func notifyPreferenceChange() {
        ActivityIslandPreferenceSignal.post()
    }

    private func setSliderEditing(_ editing: Bool) {
        isAdjustingSlider = editing
    }
}
