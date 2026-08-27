import SwiftUI

enum ActivitySettingsLayoutMode: Equatable {
    case standard
    case compact
    case narrow

    static func resolve(width: CGFloat) -> ActivitySettingsLayoutMode {
        if width < 700 { return .narrow }
        if width < 820 { return .compact }
        return .standard
    }

    var previewFraction: CGFloat {
        switch self {
        case .standard: return 0.42
        case .compact: return 0.40
        case .narrow: return 1
        }
    }

    var panePadding: CGFloat {
        self == .standard ? 20 : 14
    }

    var previewScaleFactor: CGFloat {
        switch self {
        case .standard, .narrow: return 0.60
        case .compact: return 0.47
        }
    }
}

private enum ActivitySettingsSection: String, CaseIterable, Identifiable {
    case display = "显示"
    case appearance = "外观"
    case behavior = "行为"
    case accessibility = "辅助功能"

    var id: String { rawValue }
}

private enum ActivitySettingsFocus: Hashable {
    case enabled
    case mode
    case screen
    case position
    case density
}

private struct ActivitySettingsSegmentedControl: View {
    @Binding var selection: ActivitySettingsSection
    let reduceMotion: Bool
    @Namespace private var selectionAnimation
    @State private var hoveredSection: ActivitySettingsSection?

    var body: some View {
        HStack(spacing: 1) {
            ForEach(ActivitySettingsSection.allCases) { section in
                Button {
                    select(section)
                } label: {
                    Text(section.rawValue)
                        .font(MonitorTypography.controlLarge)
                        .foregroundStyle(
                            selection == section
                                ? Color.white
                                : MonitorTheme.secondaryText
                        )
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if selection == section {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor)
                            .matchedGeometryEffect(
                                id: "activity-settings-selection",
                                in: selectionAnimation
                            )
                    } else if hoveredSection == section {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.055))
                    }
                }
                .onHover { hovering in
                    hoveredSection = hovering ? section : nil
                }
                .accessibilityLabel(section.rawValue)
                .accessibilityValue(selection == section ? "已选择" : "")
            }
        }
        .padding(2)
        .background(
            Color.white.opacity(0.085),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 0.5)
        }
        .onMoveCommand(perform: moveSelection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置分组")
    }

    private func select(_ section: ActivitySettingsSection) {
        guard section != selection else { return }
        if reduceMotion {
            selection = section
        } else {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.92)) {
                selection = section
            }
        }
    }

    private func moveSelection(_ direction: MoveCommandDirection) {
        let sections = ActivitySettingsSection.allCases
        guard let index = sections.firstIndex(of: selection) else { return }
        switch direction {
        case .left:
            select(sections[max(0, index - 1)])
        case .right:
            select(sections[min(sections.count - 1, index + 1)])
        default:
            break
        }
    }
}

/// Studio Inspector settings surface: a persistent real preview on the left
/// and a compact native inspector on the right. Existing AppStorage keys still
/// own persistence and immediate application.
struct QuotaStyleSettingsView: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
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
    @State private var selectedSection = ActivitySettingsSection.display
    @State private var isAdjustingSlider = false
    @State private var highlightedSlider: String?
    @State private var sliderFeedbackGeneration = 0
    @State private var animationStyleRevision = 0
    @State private var timeSettingsExpanded = true
    @State private var previewIsVisible = true
    @FocusState private var focusedControl: ActivitySettingsFocus?

    var body: some View {
        GeometryReader { proxy in
            let layoutMode = ActivitySettingsLayoutMode.resolve(width: proxy.size.width)
            Group {
                if layoutMode == .narrow {
                    VStack(spacing: 0) {
                        previewPane(layoutMode: layoutMode)
                            .frame(height: 238)
                        Divider().overlay(MonitorTheme.separator)
                        inspector
                    }
                } else {
                    HStack(spacing: 0) {
                        previewPane(layoutMode: layoutMode)
                            .frame(width: proxy.size.width * layoutMode.previewFraction)
                        Divider().overlay(MonitorTheme.separator)
                        inspector
                    }
                }
            }
            .animation(
                motionIsReduced ? nil : .easeOut(duration: 0.16),
                value: layoutMode
            )
        }
        .background(Color.clear)
        .onDisappear { isAdjustingSlider = false }
        .onChange(of: islandEnabled) { enabled in
            if !enabled, focusedControl != .enabled {
                focusedControl = .enabled
            }
            notifyPreferenceChange()
        }
        .onChange(of: modeRawValue) { _ in
            restoreConditionalFocusIfNeeded()
            notifyPreferenceChange()
        }
        .onChange(of: menuBarDensityRawValue) { _ in notifyPreferenceChange() }
        .onChange(of: screenRawValue) { _ in notifyPreferenceChange() }
        .onChange(of: positionRawValue) { _ in notifyPreferenceChange() }
        .onChange(of: visualStyleRawValue) { _ in
            if !motionIsReduced {
                animationStyleRevision += 1
            }
            notifyPreferenceChange()
        }
        .onChange(of: surfaceOpacity) { _ in notifyPreferenceChange() }
        .onChange(of: surfaceScale) { _ in notifyPreferenceChange() }
        .onChange(of: expandedHold) { _ in notifyPreferenceChange() }
        .onChange(of: compactHide) { _ in notifyPreferenceChange() }
        .onChange(of: reduceMotion) { _ in notifyPreferenceChange() }
        .onChange(of: showCompletion) { _ in notifyPreferenceChange() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .activitySettingsPreviewVisibilityDidChange
            )
        ) { notification in
            previewIsVisible = notification.object as? Bool ?? true
        }
    }

    private func previewPane(layoutMode: ActivitySettingsLayoutMode) -> some View {
        VStack(alignment: .leading, spacing: layoutMode == .narrow ? 8 : 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("实时预览")
                        .font(MonitorTypography.cardTitle)
                        .foregroundStyle(MonitorTheme.primaryText)
                    Text("设置会立即作用于当前显示状态。")
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer(minLength: 12)
                Text(previewStatusTitle)
                    .font(MonitorTypography.control)
                    .foregroundStyle(islandEnabled ? MonitorTheme.secondaryText : MonitorTheme.faintText)
            }

            previewStage(layoutMode: layoutMode)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if layoutMode != .narrow {
                Text(previewSummary)
                    .font(MonitorTypography.metadata)
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .padding(layoutMode.panePadding)
        .background(Color.black.opacity(0.10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("灵动岛实时预览")
        .accessibilityValue(previewSummary)
    }

    private func previewStage(layoutMode: ActivitySettingsLayoutMode) -> some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.24))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(MonitorTheme.separator, lineWidth: 0.7)

            VStack(spacing: 0) {
                previewMenuBar
                ZStack {
                    Group {
                        if !islandEnabled {
                            previewEmptyState(
                                symbol: "eye.slash",
                                title: "灵动岛已关闭",
                                detail: "菜单栏额度与本地监控仍会继续运行。"
                            )
                        } else if selectedMode == .menuBar {
                            previewEmptyState(
                                symbol: "menubar.rectangle",
                                title: "仅菜单栏",
                                detail: "实时任务状态将显示在顶部菜单栏。"
                            )
                        } else {
                            floatingIslandPreview(scaleFactor: layoutMode.previewScaleFactor)
                                .id(animationStyleRevision)
                                .transition(animationStyleTransition)
                                .frame(
                                    maxWidth: .infinity,
                                    maxHeight: .infinity,
                                    alignment: previewAlignment
                                )
                                .padding(.horizontal, 12)
                                .animation(positionAnimation, value: positionRawValue)
                                .animation(
                                    animationStyleFeedbackAnimation,
                                    value: animationStyleRevision
                                )
                        }
                    }
                    .id(previewStateID)
                    .transition(previewTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(previewAnimation, value: previewStateID)
            }
        }
    }

    private var previewMenuBar: some View {
        HStack(spacing: 8) {
            Text("Codex Monitor")
                .font(MonitorTypography.metadata)
                .foregroundStyle(MonitorTheme.tertiaryText)
            Spacer(minLength: 8)
            if islandEnabled, selectedMode == .menuBar {
                Image(systemName: liveSnapshot == nil ? "circle.dotted" : "waveform.path.ecg")
                    .font(.system(size: 9, weight: .medium))
                Text(menuBarPreviewTitle)
                    .font(MonitorTypography.metadata)
                    .lineLimit(1)
            } else {
                Image(systemName: "wifi")
                    .font(.system(size: 9, weight: .medium))
                Image(systemName: "battery.100")
                    .font(.system(size: 9, weight: .medium))
            }
        }
        .foregroundStyle(MonitorTheme.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 27)
        .background(Color.white.opacity(0.025))
        .overlay(alignment: .bottom) {
            Divider().overlay(MonitorTheme.hairline)
        }
    }

    @ViewBuilder
    private func floatingIslandPreview(scaleFactor: CGFloat) -> some View {
        let effectiveScale = CGFloat(surfaceScale) * scaleFactor
        if let snapshot = liveSnapshot {
            ActivityIslandPreview(
                snapshot: snapshot,
                style: selectedVisualStyle,
                animated: previewIsVisible && !motionIsReduced,
                surfaceOpacity: surfaceOpacity,
                surfaceScale: effectiveScale
            )
            .animation(controlResponseAnimation, value: surfaceScale)
            .animation(controlResponseAnimation, value: surfaceOpacity)
        } else {
            HStack(spacing: 2) {
                ActivityStateOrb(
                    style: selectedVisualStyle,
                    phase: nil,
                    animated: previewIsVisible && !motionIsReduced
                )
                .frame(width: 122, height: 122)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("CODEX MONITOR")
                        .font(AstaSans.semiBold(11.5))
                        .foregroundStyle(.white.opacity(0.46))
                    Text("等待真实任务状态")
                        .font(AstaSans.semiBold(17))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("检测到真实任务后会在此显示。")
                        .font(AstaSans.regular(11.5))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
            }
            .padding(.leading, 4)
            .padding(.trailing, 18)
            .frame(
                width: ActivityIslandLayout.expandedSurfaceSize.width,
                height: ActivityIslandLayout.expandedSurfaceSize.height
            )
            .background(Color.black.opacity(surfaceOpacity))
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.42), radius: 7, y: 2)
            .scaleEffect(effectiveScale)
            .frame(
                width: ActivityIslandLayout.expandedSurfaceSize.width * effectiveScale,
                height: ActivityIslandLayout.expandedSurfaceSize.height * effectiveScale
            )
            .animation(controlResponseAnimation, value: surfaceScale)
            .animation(controlResponseAnimation, value: surfaceOpacity)
        }
    }

    private func previewEmptyState(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(MonitorTheme.secondaryText)
            Text(title)
                .font(MonitorTypography.cardTitle)
                .foregroundStyle(MonitorTheme.primaryText)
            Text(detail)
                .font(MonitorTypography.body)
                .foregroundStyle(MonitorTheme.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .padding(16)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            ActivitySettingsSegmentedControl(
                selection: $selectedSection,
                reduceMotion: motionIsReduced
            )
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)

            Divider().overlay(MonitorTheme.separator)

            ScrollView(.vertical, showsIndicators: true) {
                ZStack(alignment: .topLeading) {
                    inspectorContent
                        .id(selectedSection)
                        .transition(inspectorTransition)
                }
                .animation(inspectorAnimation, value: selectedSection)
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
            .scrollDisabled(isAdjustingSlider)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.035))
    }

    @ViewBuilder
    private var inspectorContent: some View {
        switch selectedSection {
        case .display:
            displayInspector
        case .appearance:
            appearanceInspector
        case .behavior:
            behaviorInspector
        case .accessibility:
            accessibilityInspector
        }
    }

    private var displayInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeading(
                "显示",
                detail: "控制灵动岛是否显示，以及任务状态出现的位置。"
            )

            preferenceRow(
                title: "显示灵动岛",
                detail: "关闭后仍保留菜单栏额度与本地监控。"
            ) {
                Toggle("显示灵动岛", isOn: $islandEnabled)
                    .labelsHidden()
                    .focused($focusedControl, equals: .enabled)
            }

            inspectorDivider

            VStack(spacing: 0) {
                preferenceRow(
                    title: "显示方式",
                    detail: displayModeDetail
                ) {
                    Picker("显示方式", selection: $modeRawValue) {
                        ForEach(ActivityIslandMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(minWidth: 190, idealWidth: 250, maxWidth: 285)
                    .focused($focusedControl, equals: .mode)
                }

                Group {
                    if selectedMode == .floating {
                    inspectorDivider
                    preferenceRow(
                        title: "目标显示器",
                        detail: "选择浮动灵动岛所在的显示器。"
                    ) {
                        Picker("目标显示器", selection: $screenRawValue) {
                            ForEach(ActivityIslandScreenMode.allCases) { screen in
                                Text(screen.title).tag(screen.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(minWidth: 140, idealWidth: 180)
                        .focused($focusedControl, equals: .screen)
                    }

                    inspectorDivider
                    preferenceRow(
                        title: "位置",
                        detail: "选择灵动岛在屏幕顶部的水平位置。"
                    ) {
                        Picker("位置", selection: $positionRawValue) {
                            ForEach(ActivityIslandPosition.allCases) { position in
                                Text(position.title).tag(position.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(minWidth: 190, idealWidth: 250)
                        .focused($focusedControl, equals: .position)
                    }
                    } else {
                        inspectorDivider
                        preferenceRow(
                            title: "信息密度",
                            detail: "自动模式会在菜单栏空间不足时逐级收短。"
                        ) {
                            Picker("信息密度", selection: $menuBarDensityRawValue) {
                                ForEach(MenuBarInformationDensity.allCases) { density in
                                    Text(density.title).tag(density.rawValue)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(minWidth: 210, idealWidth: 285)
                            .focused($focusedControl, equals: .density)
                        }
                    }
                }
                .id(selectedMode)
                .transition(conditionalTransition)
            }
            .disabled(!islandEnabled)
            .opacity(islandEnabled ? 1 : 0.48)
            .animation(inspectorAnimation, value: selectedMode)
            .animation(inspectorAnimation, value: islandEnabled)

            if !islandEnabled {
                disabledExplanation
                    .transition(.opacity)
            }
        }
    }

    private var appearanceInspector: some View {
        inspectorGroup(
            title: "外观",
            detail: "调整浮动灵动岛的背景、尺寸和真实动画风格。",
            disabledWhenIslandHidden: true
        ) {
            opacitySliderRow
            inspectorDivider
            scaleSliderRow
            inspectorDivider
            VStack(alignment: .leading, spacing: 10) {
                Text("动画风格")
                    .font(MonitorTypography.cardTitle)
                Picker("动画风格", selection: $visualStyleRawValue) {
                    ForEach(ActivityIslandVisualStyle.allCases) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text(animationStyleDetail)
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 12)
        }
    }

    private var behaviorInspector: some View {
        inspectorGroup(
            title: "行为",
            detail: "控制任务完成反馈，以及展开和隐藏的时间。",
            disabledWhenIslandHidden: true
        ) {
            preferenceRow(
                title: "显示任务完成反馈",
                detail: "先显示完成状态，再收紧并隐藏。"
            ) {
                Toggle("显示任务完成反馈", isOn: $showCompletion)
                    .labelsHidden()
            }
            inspectorDivider
            Button {
                toggleTimeSettings()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(timeSettingsExpanded ? 90 : 0))
                    Text("时间与自动隐藏")
                        .font(MonitorTypography.cardTitle)
                    Spacer()
                }
                .foregroundStyle(MonitorTheme.primaryText)
                .frame(minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("时间与自动隐藏")
            .accessibilityValue(timeSettingsExpanded ? "已展开" : "已收起")

            if timeSettingsExpanded {
                VStack(spacing: 0) {
                    sliderRow(
                        title: "任务完成后保持展开",
                        detail: "任务完成后继续保持展开状态的时间。",
                        value: $expandedHold,
                        range: 5...60
                    )
                    inspectorDivider
                    sliderRow(
                        title: "缩小后隐藏",
                        detail: "进入紧凑态后继续显示的时间。",
                        value: $compactHide,
                        range: 5...120
                    )
                }
                .transition(disclosureTransition)
            }
        }
        .animation(disclosureAnimation, value: timeSettingsExpanded)
        .clipped()
    }

    private var accessibilityInspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeading(
                "辅助功能",
                detail: "应用内设置会与 macOS 的减少动态效果共同生效。"
            )
            preferenceRow(
                title: "减少动态效果",
                detail: "停止持续流场、粒子运动和弹性位移，只保留必要状态变化。"
            ) {
                Toggle("减少动态效果", isOn: $reduceMotion)
                    .labelsHidden()
            }
            inspectorDivider
            VStack(alignment: .leading, spacing: 6) {
                Label(
                    systemReduceMotion ? "macOS 已启用减少动态效果" : "macOS 系统动态效果正常",
                    systemImage: systemReduceMotion ? "checkmark.circle" : "circle"
                )
                .font(MonitorTypography.rowTitle)
                .foregroundStyle(MonitorTheme.secondaryText)
                Text("系统设置和应用内设置任一开启，灵动岛都会采用减少动态的呈现。")
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.tertiaryText)
            }
            .padding(.vertical, 12)
        }
    }

    private func inspectorGroup<Content: View>(
        title: String,
        detail: String,
        disabledWhenIslandHidden: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            inspectorHeading(title, detail: detail)
            content()
            if disabledWhenIslandHidden, !islandEnabled {
                disabledExplanation
                    .transition(.opacity)
            }
        }
        .disabled(disabledWhenIslandHidden && !islandEnabled)
        .opacity(disabledWhenIslandHidden && !islandEnabled ? 0.48 : 1)
        .animation(inspectorAnimation, value: islandEnabled)
    }

    private func inspectorHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MonitorTypography.pageSubtitle)
                .foregroundStyle(MonitorTheme.primaryText)
            Text(detail)
                .font(MonitorTypography.body)
                .foregroundStyle(MonitorTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 12)
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
            Spacer(minLength: 16)
            trailing()
        }
        .frame(minHeight: MonitorGeometry.settingsRowHeight)
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
                    Text(title).font(MonitorTypography.cardTitle)
                    Text(detail)
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer()
                Text("\(Int(value.wrappedValue)) 秒")
                    .font(MonitorTypography.rowTitle)
                    .foregroundStyle(
                        highlightedSlider == title
                            ? MonitorTheme.primaryText
                            : MonitorTheme.secondaryText
                    )
                    .monospacedDigit()
                    .animation(controlResponseAnimation, value: highlightedSlider)
            }
            Slider(
                value: value,
                in: range,
                step: 1,
                onEditingChanged: { editing in
                    setSliderEditing(editing, feedbackKey: title)
                }
            )
            .tint(MonitorTheme.selection)
            .accessibilityLabel(title)
            .accessibilityValue("\(Int(value.wrappedValue)) 秒")
        }
        .padding(.vertical, 12)
    }

    private var opacitySliderRow: some View {
        percentageSliderRow(
            title: "透明度",
            detail: "数值越低越透明；只调整黑色背景，不增加磨砂。",
            value: $surfaceOpacity,
            range: 0.10...0.90
        )
    }

    private var scaleSliderRow: some View {
        percentageSliderRow(
            title: "整体缩放",
            detail: "等比调整窗口、内容、光球、圆角和阴影。",
            value: $surfaceScale,
            range: 0.25...1.25
        )
    }

    private func percentageSliderRow(
        title: String,
        detail: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(MonitorTypography.cardTitle)
                    Text(detail)
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(MonitorTypography.rowTitle)
                    .foregroundStyle(
                        highlightedSlider == title
                            ? MonitorTheme.primaryText
                            : MonitorTheme.secondaryText
                    )
                    .monospacedDigit()
                    .animation(controlResponseAnimation, value: highlightedSlider)
            }
            Slider(
                value: value,
                in: range,
                step: 0.01,
                onEditingChanged: { editing in
                    setSliderEditing(editing, feedbackKey: title)
                }
            )
            .tint(MonitorTheme.selection)
            .accessibilityLabel(title)
            .accessibilityValue("\(Int((value.wrappedValue * 100).rounded()))%")
        }
        .padding(.vertical, 12)
    }

    private var inspectorDivider: some View {
        Divider().overlay(MonitorTheme.separator)
    }

    private var disabledExplanation: some View {
        Label(
            "显示灵动岛已关闭；当前值已保留，重新开启后可用。",
            systemImage: "info.circle"
        )
        .font(MonitorTypography.body)
        .foregroundStyle(MonitorTheme.tertiaryText)
        .padding(.top, 12)
        .accessibilityHint("重新开启显示灵动岛后，这些设置会恢复可用")
    }

    private var selectedMode: ActivityIslandMode {
        ActivityIslandMode(rawValue: modeRawValue) ?? .floating
    }

    private var selectedVisualStyle: ActivityIslandVisualStyle {
        ActivityIslandVisualStyle(rawValue: visualStyleRawValue) ?? .rippleGlow
    }

    private var motionIsReduced: Bool {
        systemReduceMotion || reduceMotion
    }

    private var previewAlignment: Alignment {
        switch ActivityIslandPosition(rawValue: positionRawValue) ?? .center {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private var previewStateID: String {
        guard islandEnabled else { return "closed" }
        return selectedMode.rawValue
    }

    private var previewTransition: AnyTransition {
        guard !motionIsReduced else { return .opacity }
        return .opacity.combined(with: .scale(scale: 0.98))
    }

    private var inspectorTransition: AnyTransition {
        guard !motionIsReduced else { return .opacity }
        return .opacity.combined(with: .offset(x: 0, y: 4))
    }

    private var conditionalTransition: AnyTransition {
        guard !motionIsReduced else { return .opacity }
        return .opacity.combined(with: .offset(x: 0, y: 4))
    }

    private var disclosureTransition: AnyTransition {
        guard !motionIsReduced else { return .opacity }
        return .opacity.combined(with: .offset(x: 0, y: -6))
    }

    private var animationStyleTransition: AnyTransition {
        guard !motionIsReduced else { return .identity }
        return .opacity.combined(with: .scale(scale: 0.99))
    }

    private var previewAnimation: Animation? {
        motionIsReduced
            ? .linear(duration: 0.08)
            : .easeOut(duration: 0.18)
    }

    private var inspectorAnimation: Animation? {
        motionIsReduced
            ? .linear(duration: 0.08)
            : .easeOut(duration: 0.17)
    }

    private var disclosureAnimation: Animation? {
        motionIsReduced
            ? .linear(duration: 0.08)
            : .timingCurve(0.20, 0.80, 0.20, 1, duration: 0.24)
    }

    private var positionAnimation: Animation? {
        motionIsReduced
            ? nil
            : .spring(response: 0.24, dampingFraction: 0.88)
    }

    private var controlResponseAnimation: Animation? {
        motionIsReduced
            ? nil
            : .easeOut(duration: 0.12)
    }

    private var animationStyleFeedbackAnimation: Animation? {
        motionIsReduced
            ? nil
            : .easeOut(duration: 0.18)
    }

    private var liveSnapshot: ActivityIslandSnapshot? {
        guard let project = store.focusedProject else { return nil }
        return ActivityIslandSnapshot(
            projectID: project.id,
            projectName: project.name,
            phase: project.task.phase,
            actionText: project.detailedActionSummary,
            sessionCount: project.sessionCount,
            projectCount: max(1, store.activeProjects.count),
            updatedAt: max(
                project.task.updatedAt,
                project.latestDisplayActivity?.updatedAt ?? .distantPast
            )
        )
    }

    private var displayModeDetail: String {
        selectedMode == .floating
            ? "独立显示实时任务灵动岛，同时保留菜单栏额度。"
            : "隐藏浮动灵动岛，把实时任务状态收进菜单栏。"
    }

    private var animationStyleDetail: String {
        selectedVisualStyle == .rippleGlow
            ? "Ripple Glow 使用克制的边缘能量与衰减波纹。"
            : "Particle Orb 使用中心粒子聚合与小范围轨道运动。"
    }

    private var previewStatusTitle: String {
        guard islandEnabled else { return "已关闭" }
        return selectedMode == .floating ? "浮动灵动岛" : "仅菜单栏"
    }

    private var menuBarPreviewTitle: String {
        guard let snapshot = liveSnapshot else { return "等待真实任务状态" }
        return "\(snapshot.phase.menuBarTitle) · \(snapshot.projectName)"
    }

    private var previewSummary: String {
        let state: String
        if !islandEnabled {
            state = "灵动岛关闭"
        } else if selectedMode == .menuBar {
            let density = MenuBarInformationDensity(rawValue: menuBarDensityRawValue)?.title ?? "自动"
            state = "仅菜单栏，信息密度：\(density)"
        } else {
            let screen = ActivityIslandScreenMode(rawValue: screenRawValue)?.title ?? "自动"
            let position = ActivityIslandPosition(rawValue: positionRawValue)?.title ?? "居中"
            state = "浮动灵动岛，\(screen)，\(position)"
        }
        let task = liveSnapshot == nil ? "等待真实任务状态" : "使用当前真实任务状态"
        return "\(state)；\(selectedVisualStyle.title)；缩放 \(Int((surfaceScale * 100).rounded()))%；透明度 \(Int((surfaceOpacity * 100).rounded()))%；\(motionIsReduced ? "已减少动态效果" : "动态效果开启")；\(task)。"
    }

    private func restoreConditionalFocusIfNeeded() {
        switch selectedMode {
        case .floating where focusedControl == .density:
            focusedControl = .mode
        case .menuBar where focusedControl == .screen || focusedControl == .position:
            focusedControl = .mode
        default:
            break
        }
    }

    private func notifyPreferenceChange() {
        ActivityIslandPreferenceSignal.post()
    }

    private func toggleTimeSettings() {
        if let disclosureAnimation {
            withAnimation(disclosureAnimation) {
                timeSettingsExpanded.toggle()
            }
        } else {
            timeSettingsExpanded.toggle()
        }
    }

    private func setSliderEditing(
        _ editing: Bool,
        feedbackKey: String
    ) {
        isAdjustingSlider = editing
        sliderFeedbackGeneration += 1
        let generation = sliderFeedbackGeneration
        highlightedSlider = feedbackKey
        guard !editing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            guard sliderFeedbackGeneration == generation else { return }
            highlightedSlider = nil
        }
    }
}
