import AppKit
import SwiftUI
#if canImport(Translation)
import Translation
#endif

private extension Animation {
    /// Motion language adapted from CodexIsland: entering is deliberately
    /// trackable, while dismissal gets out of the user's way more quickly.
    static let islandOpen = Animation.spring(response: 0.42, dampingFraction: 0.82)
    static let islandClose = Animation.spring(response: 0.30, dampingFraction: 0.88)
    static let islandHover = Animation.easeOut(duration: 0.12)
    static let islandPress = Animation.easeOut(duration: 0.11)
    static let islandContentSwap = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)
}

enum MonitorCenterSection: String, CaseIterable, Identifiable {
    case usage = "Usage"
    case cost = "Cost"
    case tibo = "动态中心"
    case continuity = "会话管理"
    case panelSettings = "面板设置"
    case setup = "安装与权限"
    case settings = "灵动岛设置"
    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .usage: return "chart.xyaxis.line"
        case .cost: return "dollarsign.circle"
        case .tibo: return "bolt.horizontal.circle"
        case .continuity: return "bubble.left.and.bubble.right"
        case .panelSettings: return "rectangle.on.rectangle"
        case .setup: return "checkmark.shield"
        case .settings: return "gearshape"
        }
    }

    var subtitle: String {
        switch self {
        case .usage: return "Token 与项目用量"
        case .cost: return "API 等价成本"
        case .tibo: return "额度信号、实时动态与已验证时间轴"
        case .continuity: return "本地会话连续性"
        case .panelSettings: return "管理概览卡片中的数据与操作"
        case .setup: return "首次引导、通知权限与 Codex Hooks"
        case .settings: return "Activity Island"
        }
    }
}

extension Notification.Name {
    static let monitorCenterSelectSection = Notification.Name(
        "CodexMonitor.monitorCenterSelectSection"
    )
    static let monitorCenterSectionDidChange = Notification.Name(
        "CodexMonitor.monitorCenterSectionDidChange"
    )
}

enum MonitorViewSurface {
    case notch
    case center
}

private struct AnalysisPageShell<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: MonitorGeometry.pageGap) {
                content
            }
        }
    }
}

private struct AnalysisActivityRangeMenu: View {
    @Binding var selection: ActivityPeriod

    var body: some View {
        Menu {
            ForEach(ActivityPeriod.allCases) { period in
                Button {
                    selection = period
                } label: {
                    if selection == period {
                        Label(period.rawValue, systemImage: "checkmark")
                    } else {
                        Text(period.rawValue)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text("活动范围")
                    .foregroundStyle(MonitorTheme.tertiaryText)
                Text(selection.rawValue)
                    .foregroundStyle(MonitorTheme.primaryText)
            }
            .font(MonitorTypography.metadataMedium)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(
                MonitorTheme.controlFill,
                in: RoundedRectangle(
                    cornerRadius: MonitorTheme.controlCornerRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("活动范围")
        .accessibilityValue(selection.rawValue)
    }
}

private enum TiboRadarMode: String, CaseIterable, Identifiable {
    case live = "实时动态"
    case timeline = "重置时间轴"

    var id: String { rawValue }
}

private enum TiboRadarFilter: String, CaseIterable, Identifiable {
    case all
    case reset
    case secondary

    var id: String { rawValue }
}

private enum QuotaHistoryFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case tibo = "Tibo 重置"
    case natural = "到期重置"
    case manual = "手动重置"

    var id: String { rawValue }
}

struct NotchView: View {
    @ObservedObject var store: MonitorStore
    let onToggle: () -> Void
    let onOpenCenter: (MonitorCenterSection) -> Void
    let surface: MonitorViewSurface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedPage: MonitorCenterSection
    @State private var usagePeriod: UsageTrendPeriod = .week
    @State private var usageActivityPeriod: ActivityPeriod = .month
    @State private var costActivityPeriod: ActivityPeriod = .month
    @State private var costPeriod: UsagePeriod = .day
    @State private var usageAccountScopeID = UsageAccountScope.all
    @AppStorage(ActivityIslandPreferenceKey.enabled) private var activityIslandEnabled = true
    @AppStorage(ActivityIslandPreferenceKey.mode) private var activityIslandModeRaw = ActivityIslandMode.floating.rawValue
    @State private var compactHideWorkItem: DispatchWorkItem?
    @State private var compactHovered = false
    @State private var confirmsContinuityRecovery = false
    @State private var confirmsContinuityRollback = false
    @State private var confirmsSessionImportRollback = false
    @State private var confirmsUserQuotaReset = false
    @State private var quotaResetCandidateToConfirm: QuotaResetConfirmationCandidate?
    @State private var tiboRadarMode: TiboRadarMode = .live
    @State private var tiboRadarFilter: TiboRadarFilter = .all
    @State private var monitorCenterContentOpacity = 1.0
    @State private var monitorCenterContentOffset: CGFloat = 0
    @State private var monitorCenterTransitionGeneration = 0
    @State private var tiboContentOpacity = 1.0
    @State private var tiboContentOffset: CGFloat = 0
    @State private var tiboTransitionGeneration = 0
    @State private var showsTiboQuotaHistory = false
    @State private var quotaHistoryFilter: QuotaHistoryFilter = .all
    @State private var expandedContinuityProjectID: String?
    @State private var shouldCenterExpandedContinuityProject = false
    @State private var pendingContinuityThreadDeletion: LocalThreadRecord?
    @State private var pendingContinuityProjectDeletion: ContinuityProjectGroup?

    init(
        store: MonitorStore,
        onToggle: @escaping () -> Void,
        onOpenCenter: @escaping (MonitorCenterSection) -> Void = { _ in },
        surface: MonitorViewSurface = .notch,
        initialSection: MonitorCenterSection = .usage
    ) {
        self.store = store
        self.onToggle = onToggle
        self.onOpenCenter = onOpenCenter
        self.surface = surface
        _expandedPage = State(initialValue: initialSection)
    }

    var body: some View {
        Group {
            if surface == .center {
                monitorCenterView
            } else {
                compactView
            }
        }
        .frame(
            width: surface == .center ? MonitorCenterLayout.width : IslandPanelLayout.hostWidth,
            height: surface == .center
                ? MonitorCenterLayout.height
                : IslandPanelLayout.expandedContentHeight + store.compactMenuBarHeight,
            alignment: .top
        )
        .foregroundStyle(MonitorTheme.primaryText)
        .background {
            RoundedRectangle(
                cornerRadius: surface == .center ? 0 : MonitorTheme.compactCornerRadius,
                style: .continuous
            )
            .fill(surface == .center ? Color.clear : Color.black)
            .overlay {
                if surface == .center {
                    Color.clear
                }
            }
            .shadow(
                color: .clear,
                radius: 0
            )
            .frame(
                width: surface == .center ? MonitorCenterLayout.width : store.visibleIslandWidth,
                height: surface == .center ? MonitorCenterLayout.height : store.visibleIslandHeight
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .mask(alignment: .top) {
            if surface == .center {
                Rectangle().frame(width: MonitorCenterLayout.width, height: MonitorCenterLayout.height)
            } else {
                RoundedRectangle(
                    cornerRadius: MonitorTheme.compactCornerRadius,
                    style: .continuous
                )
                .frame(width: store.visibleIslandWidth, height: store.visibleIslandHeight)
            }
        }
        .preferredColorScheme(surface == .center ? .dark : nil)
        .onReceive(
            NotificationCenter.default.publisher(for: .monitorCenterSelectSection)
        ) { notification in
            guard surface == .center,
                  let section = notification.object as? MonitorCenterSection
            else { return }
            showPage(section)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if surface == .center, let draft = store.sessionExportDraft {
                sessionExportConfigurationOverlay(draft)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: store.sessionExportDraft?.id
        )
    }

    private var compactView: some View {
        VStack(spacing: 0) {
            compactTopRow
                .frame(height: store.compactMenuBarHeight)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)

            if store.compactProjectsHeight > 0 {
                compactProjectBoard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(width: store.compactPanelWidth, height: store.compactPanelHeight)
        // Background gradients on the fixed left/right controls are rectangular.
        // Clip the complete compact hierarchy—not only its black backdrop—so
        // those internal layers cannot protrude through the rounded side arcs.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .circular))
        .overlay {
            if hasLiveActivity {
                CompactOrbitGlow(color: statusColor, animated: !reduceMotion)
                    .allowsHitTesting(false)
            }
        }
        .opacity(store.compactContentVisible ? 1 : 0)
        .blur(radius: store.compactContentVisible ? 0 : 1)
        .allowsHitTesting(store.compactContentVisible && !store.isExpansionTransitioning)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.08),
            value: store.compactContentVisible
        )
        .onHover(perform: handleCompactHover)
        .onDisappear {
            compactHideWorkItem?.cancel()
            compactHideWorkItem = nil
        }
    }

    private func handleCompactHover(_ hovering: Bool) {
        animate(.islandHover) { compactHovered = hovering }
        compactHideWorkItem?.cancel()
        compactHideWorkItem = nil

        if hovering {
            guard !store.compactDetailsVisible else { return }
            animate(.islandOpen) { store.compactDetailsVisible = true }
            return
        }

        // Keep the project board stable while the pointer crosses its edge or
        // moves toward a project button. Approval details remain forced open.
        let workItem = DispatchWorkItem {
            guard store.approvalProjectCount == 0 else { return }
            animate(.islandClose) { store.compactDetailsVisible = false }
        }
        compactHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: workItem)
    }

    @ViewBuilder
    private var compactProjectBoard: some View {
        let projects = store.compactVisibleProjects
        if projects.count == 1, let project = projects.first {
            VStack(spacing: 0) {
                compactHorizontalDivider
                compactProjectCell(project, height: 21, singleLine: true)
            }
        } else if projects.count == 2 {
            VStack(spacing: 0) {
                compactHorizontalDivider
                HStack(spacing: 0) {
                    compactProjectCell(projects[0], height: 37, singleLine: false)
                    compactVerticalDivider
                    compactProjectCell(projects[1], height: 37, singleLine: false)
                }
            }
        } else if projects.count == 3 && store.activeProjects.count == 3 {
            VStack(spacing: 0) {
                compactHorizontalDivider
                HStack(spacing: 0) {
                    compactProjectCell(projects[0], height: 30, singleLine: false)
                    compactVerticalDivider
                    compactProjectCell(projects[1], height: 30, singleLine: false)
                }
                compactHorizontalDivider
                compactProjectCell(projects[2], height: 30, singleLine: true)
            }
        } else if projects.count >= 3 {
            VStack(spacing: 0) {
                compactHorizontalDivider
                HStack(spacing: 0) {
                    compactProjectCell(projects[0], height: 30, singleLine: false)
                    compactVerticalDivider
                    compactProjectCell(projects[1], height: 30, singleLine: false)
                }
                compactHorizontalDivider
                HStack(spacing: 0) {
                    compactProjectCell(projects[2], height: 30, singleLine: false)
                    compactVerticalDivider
                    if store.activeProjects.count > 4 {
                        CompactMoreProjectsCell(
                            count: store.activeProjects.count - 3,
                            height: 30,
                            action: onToggle
                        )
                    } else {
                        compactProjectCell(projects[3], height: 30, singleLine: false)
                    }
                }
            }
        }
    }

    private var compactHorizontalDivider: some View {
        Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
    }

    private var compactVerticalDivider: some View {
        Rectangle().fill(.white.opacity(0.07)).frame(width: 1)
    }

    private func compactProjectCell(
        _ project: ActiveProjectState,
        height: CGFloat,
        singleLine: Bool
    ) -> some View {
        CompactProjectCell(
            project: project,
            actionText: projectActionText(project),
            height: height,
            singleLine: singleLine,
            isFocused: store.focusedProject?.id == project.id
        ) {
            store.selectProject(project.id)
            onToggle()
        }
    }

    private var compactTopRow: some View {
        Group {
            if store.usesNotchLayout {
                notchedCompactTopRow
            } else {
                standardCompactTopRow
            }
        }
    }

    private var notchedCompactTopRow: some View {
        HStack(spacing: 0) {
            statusWing
            .padding(.leading, 14)
            .frame(width: compactWingWidth, alignment: .leading)
            .clipped()

            // A real three-zone layout: neither wing is allowed to lay out into
            // the physical camera span, even when labels are compressed.
            Color.clear
                .frame(width: compactCameraGapWidth)
                .allowsHitTesting(false)

            quotaWing
                .padding(.trailing, 14)
                .frame(width: compactWingWidth, alignment: .trailing)
                .clipped()
        }
    }

    /// Standard Intel MacBooks and ordinary external displays have no opaque
    /// camera housing to merge with. Use one compact, balanced capsule instead
    /// of preserving a fake central gap.
    private var standardCompactTopRow: some View {
        HStack(spacing: 10) {
            statusWing
            Spacer(minLength: 8)
            quotaWing
        }
        .padding(.horizontal, 12)
    }

    private var statusWing: some View {
        HStack(spacing: 8) {
            GPTStatusMark(
                active: hasLiveActivity,
                color: statusColor,
                refreshToken: compactStatusRefreshToken,
                animated: hasLiveActivity && !reduceMotion
            )
            Text(compactTopStatusText)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 9)
        .frame(height: 23)
        .background(
            Capsule(style: .continuous)
                .fill(idleAccent.opacity(compactHovered ? 0.13 : 0.075))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(idleAccent.opacity(compactHovered ? 0.30 : 0.16), lineWidth: 0.6)
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Codex \(compactTopStatusText)")
    }

    private var compactCameraGapWidth: CGFloat {
        min(store.notchObstructionWidth, max(0, store.compactPanelWidth - 180))
    }

    private var compactWingWidth: CGFloat {
        max(90, (store.compactPanelWidth - compactCameraGapWidth) / 2)
    }

    @ViewBuilder
    private var quotaWing: some View {
        HStack(spacing: 6) {
            if let window = store.quotaState.primaryBucket?.limitingWindow {
                QuotaMiniGauge(
                    remainingPercent: window.remainingPercent,
                    color: quotaColor(for: window.remainingPercent)
                )
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(quotaColor(for: window.remainingPercent))
                    .monospacedDigit()
                if quotaDataIsStale {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.orange)
                        .help(quotaErrorText ?? "额度数据可能已过期")
                }
            } else if case .loading = store.quotaState {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                HStack(spacing: 3) {
                    Text("--%")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 7, weight: .bold))
                }
                .foregroundStyle(.orange)
                .help(quotaErrorText ?? "暂时无法读取额度，正在自动重试")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 23)
        .background(
            Capsule(style: .continuous)
                .fill(quotaAccent.opacity(compactHovered ? 0.11 : 0.06))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(quotaAccent.opacity(compactHovered ? 0.26 : 0.13), lineWidth: 0.6)
                }
        )
    }

    private func quotaColor(for remainingPercent: Int) -> Color {
        if remainingPercent < 20 { return .red }
        if remainingPercent < 50 { return .orange }
        return quotaAccent
    }

    private var glancePopover: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                CodexMark(size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CODEX MONITOR")
                        .font(.system(size: 10.5, weight: .bold, design: .rounded))
                        .tracking(1.05)
                    Text(store.focusedProject?.task.phase.title ?? "额度与用量概览")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer()
                Button { store.refreshAll() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IslandButtonStyle())
                Button { openCenter(.settings) } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(IslandButtonStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 15)
            .padding(.bottom, 12)

            Divider().overlay(.white.opacity(0.08))

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    glanceQuotaSummary
                    Divider().overlay(.white.opacity(0.07))
                    glanceUsageCostSummary
                    Divider().overlay(.white.opacity(0.07))
                    glanceCenterActions
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(!activityIslandEnabled || store.activeProjects.isEmpty ? Color.gray : statusColor)
                    .frame(width: 5, height: 5)
                Text(
                    !activityIslandEnabled
                        ? "Activity Island 已关闭"
                        : activityIslandModeStatusText
                )
                Spacer()
                Text("数据仅在本机处理")
            }
            .font(.system(size: 7.5, weight: .medium))
            .foregroundStyle(MonitorTheme.faintText)
            .padding(.horizontal, 15)
            .padding(.bottom, 11)
        }
        .frame(width: IslandPanelLayout.glanceWidth, height: IslandPanelLayout.expandedContentHeight)
        .opacity(store.expandedContentVisible ? 1 : 0)
        .offset(y: reduceMotion || store.expandedContentVisible ? 0 : -6)
        .allowsHitTesting(store.expandedContentVisible && !store.isExpansionTransitioning)
        .animation(reduceMotion ? nil : .islandContentSwap, value: store.expandedContentVisible)
    }

    private var glanceQuotaSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("额度")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MonitorTheme.secondaryText)
                Spacer()
                quotaFreshness
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(MonitorTheme.faintText)
            }
            if store.quotaState.buckets.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(.cyan)
                    Text(quotaErrorText ?? "正在连接 Codex App Server…")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 42)
            } else {
                ForEach(store.quotaState.buckets.prefix(2)) { bucket in
                    ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                        QuotaRow(bucket: bucket, window: window)
                    }
                }
            }
        }
        .padding(12)
    }

    private var glanceUsageCostSummary: some View {
        let usage = store.costSnapshot.aggregate.usage.day
        let cost = store.costSnapshot.aggregate.today
        return HStack(spacing: 0) {
            glanceMetric(
                title: "今日 Token",
                value: formatCompactTokens(usage.tokens),
                detail: "\(usage.sessionCount) 会话 · \(usage.projectCount) 项目",
                color: MonitorTheme.cyanAccent
            )
            Divider()
                .frame(height: 48)
                .overlay(.white.opacity(0.08))
                .padding(.horizontal, 12)
            glanceMetric(
                title: "今日 Cost",
                value: formatDollars(cost.dollars),
                detail: "API 等价估算",
                color: Color(red: 0.63, green: 0.55, blue: 1.00)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    private func glanceMetric(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(MonitorTheme.tertiaryText)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(detail)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(MonitorTheme.faintText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var glanceCenterActions: some View {
        VStack(spacing: 0) {
            glanceActionRow(.usage, trailing: "趋势与热力图")
            Divider().overlay(.white.opacity(0.06)).padding(.leading, 34)
            glanceActionRow(.cost, trailing: "估算与模型")
            Divider().overlay(.white.opacity(0.06)).padding(.leading, 34)
            glanceActionRow(.tibo, trailing: store.tiboFeedError == nil ? "最新额度动态" : "数据可能延迟")
            Divider().overlay(.white.opacity(0.06)).padding(.leading, 34)
            glanceActionRow(
                .continuity,
                trailing: store.continuitySnapshot.recoverableThreads.isEmpty
                    ? "\(store.continuitySnapshot.sessionCount) 条会话"
                    : "\(store.continuitySnapshot.recoverableThreads.count) 条待恢复"
            )
        }
        .padding(.horizontal, 11)
    }

    private func glanceActionRow(_ section: MonitorCenterSection, trailing: String) -> some View {
        Button { openCenter(section) } label: {
            HStack(spacing: 9) {
                Image(systemName: section.symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(MonitorTheme.cyanAccent.opacity(0.86))
                    .frame(width: 18)
                Text(section.rawValue)
                    .font(.system(size: 9.5, weight: .semibold))
                Spacer(minLength: 6)
                Text(trailing)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(MonitorTheme.faintText)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.white.opacity(0.24))
            }
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openCenter(_ section: MonitorCenterSection) {
        onToggle()
        onOpenCenter(section)
    }

    private var activityIslandModeStatusText: String {
        switch ActivityIslandMode(rawValue: activityIslandModeRaw) ?? .floating {
        case .floating:
            return store.activeProjects.isEmpty
                ? "Activity Island 待命"
                : "Activity Island 正在显示实时任务"
        case .menuBar:
            return "仅菜单栏状态模式"
        }
    }

    private var monitorCenterView: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    CodexMark(size: 27)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Codex Monitor")
                            .font(AstaSans.semiBold(15))
                            .tracking(-0.15)
                        Text("本地用量与会话")
                            .font(AstaSans.regular(9))
                            .foregroundStyle(MonitorTheme.tertiaryText)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 34)
                .padding(.bottom, 22)

                VStack(spacing: 3) {
                    ForEach(MonitorCenterSection.allCases) { section in
                        Button { showPage(section) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: section.symbol)
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(width: 19)
                                    .accessibilityHidden(true)
                        Text(section.rawValue)
                                    .font(MonitorTypography.controlLarge)
                                Spacer(minLength: 0)
                                if section == .continuity,
                                   !store.continuitySnapshot.recoverableThreads.isEmpty {
                                    Text("\(store.continuitySnapshot.recoverableThreads.count)")
                                        .font(AstaSans.semiBold(9))
                                        .foregroundStyle(.orange)
                                }
                            }
                            .foregroundStyle(expandedPage == section ? .white.opacity(0.96) : MonitorTheme.secondaryText)
                            .padding(.horizontal, 12)
                            .frame(maxWidth: .infinity, minHeight: 39)
                            .background(
                                expandedPage == section ? MonitorTheme.selection : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: 0.12),
                                value: expandedPage
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(section.rawValue)
                        .accessibilityValue(
                            expandedPage == section ? "当前页面" : ""
                        )
                        .accessibilityAddTraits(
                            expandedPage == section ? .isSelected : []
                        )
                        .accessibilityRemoveTraits(
                            expandedPage == section ? [] : .isSelected
                        )
                    }
                }
                .padding(.horizontal, 17)

                Spacer()

                VStack(alignment: .leading, spacing: 5) {
                    Label("所有数据仅在本机处理", systemImage: "lock.fill")
                    Text(store.continuityAccountSubtitle ?? store.continuityAccountTitle)
                        .lineLimit(2)
                }
                .font(AstaSans.regular(9))
                .foregroundStyle(MonitorTheme.faintText)
                .padding(24)
            }
            .frame(width: MonitorCenterLayout.sidebarWidth)
            .background(Color.black.opacity(0.08))

            Divider().overlay(MonitorTheme.separator)

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expandedPage.rawValue)
                            .font(MonitorTypography.pageTitle)
                            .tracking(-0.21)
                        Text(expandedPage.subtitle)
                            .font(MonitorTypography.pageSubtitle)
                            .foregroundStyle(MonitorTheme.tertiaryText)
                    }
                    Spacer()
                    if monitorCenterPageIsRefreshing {
                        ProgressView().controlSize(.small).tint(.cyan)
                    }
                    if monitorCenterPageCanRefresh {
                        Button { refreshCurrentMonitorCenterPage() } label: {
                            Label(
                                monitorCenterRefreshTitle,
                                systemImage: "arrow.clockwise"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 31)
                .padding(.bottom, 17)

                Divider().overlay(MonitorTheme.separator)

                monitorCenterDetail
                    .opacity(monitorCenterContentOpacity)
                    .offset(y: monitorCenterContentOffset)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
            }
        }
        .font(AstaSans.regular(10.5))
        .frame(width: MonitorCenterLayout.width, height: MonitorCenterLayout.height)
        .background(Color.clear)
    }

    private func sessionExportConfigurationOverlay(_ draft: SessionExportDraft) -> some View {
        ZStack {
            Color.black.opacity(0.48)
                .contentShape(Rectangle())

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: draft.selectedFormat == .projectBundle
                        ? "shippingbox.fill"
                        : "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .frame(width: 38, height: 38)
                        .background(Color.cyan.opacity(0.10), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(draft.title)
                            .font(AstaSans.semiBold(18))
                        Text(sessionExportOverlaySubtitle)
                            .font(AstaSans.regular(9.5))
                            .foregroundStyle(MonitorTheme.tertiaryText)
                    }
                    Spacer()
                    Button { store.cancelSessionExportDraft() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(MonitorTheme.controlFill, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isSessionExporting)
                    .opacity(store.isSessionExporting ? 0.35 : 1)
                    .help(store.isSessionExporting ? "导出进行中" : "关闭导出面板")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

                Divider().overlay(MonitorTheme.separator)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        if store.isSessionExporting || store.lastSessionExportURL != nil {
                            sessionExportOperationSection(draft)
                        } else {
                            if let error = store.continuityError {
                                continuityMessageCard(error, color: .orange)
                            }
                            sessionExportDestinationSection(draft)
                            sessionExportFormatSection(draft)
                            if draft.selectedFormat == .projectBundle {
                                sessionExportProjectOptionsSection(draft)
                            }
                        }
                    }
                    .padding(18)
                }

                Divider().overlay(MonitorTheme.separator)

                if store.isSessionExporting {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small).tint(.cyan)
                        Text("如果 macOS 请求项目目录权限，请先完成系统提示。")
                            .font(AstaSans.regular(8.8))
                            .foregroundStyle(MonitorTheme.tertiaryText)
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                } else if store.lastSessionExportURL != nil {
                    HStack(spacing: 10) {
                        Label("导出文件已安全写入所选位置。", systemImage: "checkmark.circle.fill")
                            .font(AstaSans.regular(8.8))
                            .foregroundStyle(.green)
                        Spacer(minLength: 10)
                        Button("在 Finder 中显示") { store.revealLastSessionExport() }
                            .buttonStyle(.plain)
                            .font(AstaSans.semiBold(9.5))
                            .foregroundStyle(.cyan)
                        Button("完成") { store.cancelSessionExportDraft() }
                            .font(AstaSans.semiBold(10))
                            .frame(width: 72, height: 32)
                            .background(MonitorTheme.selection, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                } else {
                    HStack(spacing: 10) {
                        Label(
                            draft.selectedFormat == .projectBundle
                                ? "项目源码和原始会话可能含敏感信息，请勿公开分享。"
                                : "可读副本会隐藏平台注入配置和内部元数据。",
                            systemImage: "lock.shield"
                        )
                        .font(AstaSans.regular(8.8))
                        .foregroundStyle(MonitorTheme.tertiaryText)
                        .lineLimit(2)
                        Spacer(minLength: 10)
                        Button("取消") { store.cancelSessionExportDraft() }
                            .buttonStyle(.plain)
                            .font(AstaSans.semiBold(10))
                            .foregroundStyle(MonitorTheme.secondaryText)
                            .frame(width: 72, height: 32)
                            .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        Button {
                            store.confirmSessionExport()
                        } label: {
                            Label("开始导出", systemImage: "arrow.up.doc.fill")
                                .font(AstaSans.semiBold(10))
                                .frame(width: 108, height: 32)
                                .background(MonitorTheme.selection, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(draft.filenameStem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(draft.filenameStem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.45 : 1)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                }
            }
            .frame(width: 570, height: draft.selectedFormat == .projectBundle ? 548 : 430)
            .background(
                Color(red: 0.075, green: 0.075, blue: 0.082).opacity(0.92),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.5), radius: 28, y: 14)
        }
        .frame(width: MonitorCenterLayout.width, height: MonitorCenterLayout.height)
    }

    private var sessionExportOverlaySubtitle: String {
        if store.lastSessionExportURL != nil { return "导出已完成，可在 Finder 中查看文件。" }
        guard store.isSessionExporting else { return "先确认内容范围，再直接导出到指定文件夹。" }
        switch store.sessionExportProgress?.stage {
        case .reading: return "目录权限已返回，正在扫描项目文件。"
        case .processing, .rendering, .writing: return "正在生成导出内容，请保持面板打开。"
        case .compressing: return "扫描已完成，正在生成压缩包。"
        case .completed: return "导出已完成，正在确认输出文件。"
        case .preparing, .none: return "等待目录授权或开始扫描…"
        }
    }

    @ViewBuilder
    private func sessionExportOperationSection(_ draft: SessionExportDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let progress = store.sessionExportProgress {
                sessionExportProgressCard(progress)
            }
            if store.lastSessionExportURL != nil {
                sessionExportCompletedCard
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: draft.selectedFormat == .projectBundle ? "folder.badge.gearshape" : "doc.badge.gearshape")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(sessionExportOverlaySubtitle)
                            .font(AstaSans.semiBold(10.5))
                        Text(draft.destinationDirectory.appendingPathComponent(draft.outputFilename).path)
                            .font(AstaSans.regular(8.5))
                            .foregroundStyle(MonitorTheme.tertiaryText)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(13)
                .background(MonitorTheme.subtleCardFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            }
        }
    }

    private func sessionExportDestinationSection(_ draft: SessionExportDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("文件与位置")
                .font(AstaSans.semiBold(10.5))

            HStack(spacing: 0) {
                TextField(
                    "文件名",
                    text: Binding(
                        get: { store.sessionExportDraft?.filenameStem ?? "" },
                        set: { store.updateSessionExportFilenameStem($0) }
                    )
                )
                .textFieldStyle(.plain)
                .font(AstaSans.medium(10.5))
                .padding(.leading, 12)
                Text(".\(draft.selectedFormat.fileExtension)")
                    .font(AstaSans.medium(9.5))
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .padding(.trailing, 12)
            }
            .frame(height: 36)
            .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.7)
            }

            HStack(spacing: 9) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(draft.destinationDirectory.lastPathComponent)
                        .font(AstaSans.semiBold(9.5))
                    Text(draft.destinationDirectory.path)
                        .font(AstaSans.regular(8))
                        .foregroundStyle(MonitorTheme.faintText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("更改") { store.chooseSessionExportDirectory() }
                    .buttonStyle(.plain)
                    .font(AstaSans.semiBold(9))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 10)
                    .frame(height: 27)
                    .background(Color.cyan.opacity(0.08), in: Capsule())
            }
            .padding(.horizontal, 12)
            .frame(height: 45)
            .background(MonitorTheme.subtleCardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func sessionExportFormatSection(_ draft: SessionExportDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("导出格式")
                .font(AstaSans.semiBold(10.5))
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                spacing: 8
            ) {
                ForEach(draft.availableFormats, id: \.rawValue) { format in
                    Button { store.updateSessionExportFormat(format) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: sessionExportFormatIcon(format))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(draft.selectedFormat == format ? .cyan : MonitorTheme.secondaryText)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(format.title)
                                    .font(AstaSans.semiBold(9.5))
                                    .lineLimit(1)
                                Text(sessionExportFormatSummary(format))
                                    .font(AstaSans.regular(7.8))
                                    .foregroundStyle(MonitorTheme.tertiaryText)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 3)
                            Image(systemName: draft.selectedFormat == format ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(draft.selectedFormat == format ? .cyan : MonitorTheme.faintText)
                        }
                        .padding(.horizontal, 11)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(
                            draft.selectedFormat == format
                                ? Color.cyan.opacity(0.09)
                                : MonitorTheme.subtleCardFill,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    draft.selectedFormat == format
                                        ? Color.cyan.opacity(0.42)
                                        : Color.white.opacity(0.06),
                                    lineWidth: 0.8
                                )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sessionExportProjectOptionsSection(_ draft: SessionExportDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("完整项目迁移范围")
                    .font(AstaSans.semiBold(10.5))
                Spacer()
                if let estimate = draft.projectEstimate {
                    Text("默认 \(estimate.includedFileCount) 个文件 · \(ByteCountFormatter.string(fromByteCount: estimate.includedBytes, countStyle: .file))")
                        .font(AstaSans.medium(8.5))
                        .foregroundStyle(.cyan.opacity(0.82))
                        .monospacedDigit()
                }
            }

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)],
                spacing: 7
            ) {
                sessionExportOption(
                    title: "Git 未跟踪文件",
                    subtitle: "继续应用敏感与体积排除",
                    keyPath: \.includeUntrackedFiles,
                    draft: draft
                )
                sessionExportOption(
                    title: "本地附件",
                    subtitle: "包含会话引用且可读取的附件",
                    keyPath: \.includeAttachments,
                    draft: draft
                )
                sessionExportOption(
                    title: "历史部署目录",
                    subtitle: "默认关闭，通常可在目标机重建",
                    keyPath: \.includeDeploymentArtifacts,
                    draft: draft
                )
                sessionExportOption(
                    title: "ZIP、DMG 等归档",
                    subtitle: "默认关闭，避免重复打包",
                    keyPath: \.includeArchives,
                    draft: draft
                )
                sessionExportOption(
                    title: "≥ 25 MB 其他文件",
                    subtitle: "默认关闭，避免迁移包异常膨胀",
                    keyPath: \.includeLargeFiles,
                    draft: draft
                )
            }

            if let estimate = draft.projectEstimate {
                Text("安全范围外另发现：\(estimate.excludedDeploymentCount) 个部署目录、\(estimate.excludedArchiveCount) 个归档、\(estimate.excludedLargeFileCount) 个大型文件。打开对应选项后才会纳入。")
                    .font(AstaSans.regular(8.2))
                    .foregroundStyle(MonitorTheme.faintText)
            }
        }
    }

    private func sessionExportOption(
        title: String,
        subtitle: String,
        keyPath: WritableKeyPath<ProjectTransferExportOptions, Bool>,
        draft: SessionExportDraft
    ) -> some View {
        let isEnabled = draft.projectTransferOptions[keyPath: keyPath]
        return Button {
            var options = draft.projectTransferOptions
            options[keyPath: keyPath].toggle()
            store.updateSessionExportOptions(options)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isEnabled ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isEnabled ? .cyan : MonitorTheme.faintText)
                    .frame(width: 17)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AstaSans.semiBold(9))
                    Text(subtitle)
                        .font(AstaSans.regular(7.6))
                        .foregroundStyle(MonitorTheme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 43)
            .background(
                isEnabled ? Color.cyan.opacity(0.055) : MonitorTheme.subtleCardFill,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func sessionExportFormatIcon(_ format: SessionExportFormat) -> String {
        switch format {
        case .markdown: return "text.document"
        case .html: return "safari"
        case .portableBundle: return "archivebox"
        case .projectBundle: return "shippingbox"
        }
    }

    private func sessionExportFormatSummary(_ format: SessionExportFormat) -> String {
        switch format {
        case .markdown: return "适合阅读，隐藏敏感元数据"
        case .html: return "浏览器阅读，带问题导航"
        case .portableBundle: return "保留原始会话，可用于恢复"
        case .projectBundle: return "源码、会话、Git 与附件"
        }
    }

    @ViewBuilder
    private var monitorCenterDetail: some View {
        switch expandedPage {
        case .usage:
            AnalysisPageShell {
                analysisAccountScopeBar
                usageActivityCard
                analysisPeriodBar
                usageOverviewCard
                usageProjectCard
                quotaCard
            }
        case .cost:
            AnalysisPageShell {
                analysisAccountScopeBar
                costActivityCard
                analysisPeriodBar
                costOverviewCard
                providerCostCard
            }
        case .tibo:
            tiboPage
        case .continuity:
            continuityPage
        case .panelSettings:
            GlanceContentSettingsView()
        case .setup:
            SetupPermissionsView(store: store)
        case .settings:
            MonitorSettingsView(store: store)
        }
    }

    private func showPage(_ page: MonitorCenterSection) {
        if surface == .center, page == .settings {
            onOpenCenter(.settings)
            return
        }
        if expandedPage != page {
            transitionMonitorCenter(to: page)
        }
        NotificationCenter.default.post(
            name: .monitorCenterSectionDidChange,
            object: page
        )
    }

    private func transitionMonitorCenter(to page: MonitorCenterSection) {
        monitorCenterTransitionGeneration += 1
        let generation = monitorCenterTransitionGeneration
        if reduceMotion {
            expandedPage = page
            monitorCenterContentOpacity = 1
            monitorCenterContentOffset = 0
            return
        }

        monitorCenterContentOpacity = 0.35
        monitorCenterContentOffset = 3
        expandedPage = page
        DispatchQueue.main.async {
            guard monitorCenterTransitionGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.16)) {
                monitorCenterContentOpacity = 1
                monitorCenterContentOffset = 0
            }
        }
    }

    private var monitorCenterPageCanRefresh: Bool {
        switch expandedPage {
        case .usage, .cost, .tibo, .continuity:
            return true
        case .panelSettings, .setup, .settings:
            return false
        }
    }

    private var monitorCenterPageIsRefreshing: Bool {
        switch expandedPage {
        case .usage, .cost:
            return store.isCostLoading
        case .tibo:
            return store.isTiboFeedLoading
        case .continuity:
            return store.isContinuityLoading
        case .panelSettings, .setup, .settings:
            return false
        }
    }

    private var monitorCenterRefreshTitle: String {
        expandedPage == .continuity ? "重新检查" : "刷新"
    }

    private func refreshCurrentMonitorCenterPage() {
        switch expandedPage {
        case .usage, .cost:
            store.refreshQuota()
            store.refreshCost()
        case .tibo:
            store.refreshQuota()
            store.refreshTiboFeed()
        case .continuity:
            store.refreshContinuity(forceInventory: true)
        case .panelSettings, .setup, .settings:
            break
        }
    }

    private func animate(_ animation: Animation, updates: () -> Void) {
        if reduceMotion {
            updates()
        } else {
            withAnimation(animation, updates)
        }
    }

    private var continuityPage: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    continuityOverviewCard
                    if store.pendingSidebarCleanupCount > 0 {
                        sidebarCleanupPendingCard
                    }
                    if store.isSessionImportInspecting {
                        sessionImportInspectionCard
                    }
                    if let preview = store.sessionImportPreview {
                        sessionImportPreviewCard(preview)
                    }
                    if let preview = store.projectTransferPreview {
                        projectTransferPreviewCard(preview)
                    }
                    if let progress = store.sessionImportProgress {
                        sessionImportProgressCard(progress)
                    }
                    if let progress = store.sessionExportProgress {
                        sessionExportProgressCard(progress)
                    }
                    if store.lastSessionExportURL != nil,
                       store.sessionExportProgress == nil {
                        sessionExportCompletedCard
                    }
                    if let message = store.continuityStatusMessage,
                       !store.isSessionImportInspecting {
                        continuityMessageCard(
                            message,
                            color: continuityStatusMessageColor(message)
                        )
                    }
                    if let error = store.continuityError {
                        continuityMessageCard(error, color: .orange)
                    }
                    continuityThreadCard
                    if store.lastContinuityBackupURL != nil {
                        continuityBackupCard
                    }
                    if store.lastSessionImportBackupURL != nil {
                        sessionImportBackupCard
                    }
                    if store.lastProjectImportBackupURL != nil {
                        projectImportBackupCard
                    }
                    if let outcome = store.lastSessionImportOutcome {
                        sessionImportOutcomeCard(outcome)
                    }
                }
            }
            .onChange(of: expandedContinuityProjectID) { projectID in
                guard shouldCenterExpandedContinuityProject,
                      let projectID
                else { return }
                shouldCenterExpandedContinuityProject = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.24)) {
                        proxy.scrollTo(continuityProjectScrollID(projectID), anchor: .center)
                    }
                }
            }
        }
        .alert("备份并恢复本地会话", isPresented: $confirmsContinuityRecovery) {
            Button("取消", role: .cancel) { }
            Button("备份并恢复") { store.recoverHiddenThreads() }
        } message: {
            Text("请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop。插件会先备份本地索引，再通过官方 App Server 重新扫描会话；不会改写原始 JSONL 对话。")
        }
        .alert("恢复到操作前", isPresented: $confirmsContinuityRollback) {
            Button("取消", role: .cancel) { }
            Button("确认回滚") { store.rollbackLastContinuityRecovery() }
        } message: {
            Text("请先完全退出 Codex／ChatGPT Desktop。当前索引会先保存到备份目录，再恢复上次操作前的状态。")
        }
        .alert("撤销上次导入", isPresented: $confirmsSessionImportRollback) {
            Button("取消", role: .cancel) { }
            Button("确认撤销") { store.rollbackLastSessionImport() }
        } message: {
            Text("请先完全退出 Codex／ChatGPT Desktop。本次新建的会话将被移除，导入前的索引和项目状态将从校验备份恢复。")
        }
        .alert(
            "永久删除会话？",
            isPresented: Binding(
                get: { pendingContinuityThreadDeletion != nil },
                set: { if !$0 { pendingContinuityThreadDeletion = nil } }
            ),
            presenting: pendingContinuityThreadDeletion
        ) { thread in
            Button("取消", role: .cancel) {
                pendingContinuityThreadDeletion = nil
            }
            Button("永久删除", role: .destructive) {
                pendingContinuityThreadDeletion = nil
                store.deleteContinuityThread(thread)
            }
        } message: { thread in
            Text(
                "将通过 Codex App Server 永久删除「\(thread.title)」"
                    + (thread.isArchived ? "（已归档）" : "（活动会话）")
                    + "。删除后无法撤销；如需保留，请先导出可恢复备份。"
            )
        }
        .alert(
            "永久删除项目会话？",
            isPresented: Binding(
                get: { pendingContinuityProjectDeletion != nil },
                set: { if !$0 { pendingContinuityProjectDeletion = nil } }
            ),
            presenting: pendingContinuityProjectDeletion
        ) { project in
            Button("取消", role: .cancel) {
                pendingContinuityProjectDeletion = nil
            }
            Button("仅移除 Codex 项目", role: .destructive) {
                pendingContinuityProjectDeletion = nil
                store.deleteContinuityProject(
                    project,
                    deleteProjectDirectory: false
                )
            }
            Button("同时移到废纸篓", role: .destructive) {
                pendingContinuityProjectDeletion = nil
                store.deleteContinuityProject(
                    project,
                    deleteProjectDirectory: true
                )
            }
        } message: { project in
            Text(projectDeletionMessage(project))
        }
        .alert(
            "删除失败",
            isPresented: Binding(
                get: { store.continuityDeletionFailure != nil },
                set: { if !$0 { store.dismissContinuityDeletionFailure() } }
            ),
            presenting: store.continuityDeletionFailure
        ) { _ in
            Button("知道了") {
                store.dismissContinuityDeletionFailure()
            }
        } message: { message in
            Text(message)
        }
    }

    private var continuityOverviewCard: some View {
        VStack(spacing: 0) {
            continuityAccountCard
            Divider().overlay(MonitorTheme.separator)
            continuitySummaryCard
        }
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(
                cornerRadius: MonitorGeometry.cardRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: MonitorGeometry.cardRadius,
                style: .continuous
            )
            .strokeBorder(MonitorTheme.hairline, lineWidth: 0.5)
        }
    }

    private var continuityAccountCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.12)).frame(width: 36, height: 36)
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(store.continuityAccountTitle)
                    .font(MonitorTypography.cardTitle)
                if let subtitle = store.continuityAccountSubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
            }
            Spacer()
            if store.isContinuityLoading {
                ProgressView().controlSize(.small).tint(.cyan)
            }
        }
        .padding(MonitorGeometry.compactPadding)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: store.activeProjects.count
        )
    }

    private func sessionExportProgressCard(_ progress: SessionExportProgress) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if progress.stage == .completed {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.cyan)
                } else {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.cyan)
                }
                Text(progress.stage.rawValue)
                    .font(AstaSans.semiBold(10.5))
                Spacer()
                Text(
                    progress.total > 0
                        ? "\(Int((progress.fraction * 100).rounded()))% · \(progress.completed) / \(progress.total)"
                        : "\(Int((progress.fraction * 100).rounded()))% · 已扫描 \(progress.completed) 项"
                )
                    .font(AstaSans.semiBold(9.5))
                    .foregroundStyle(.cyan)
                    .monospacedDigit()
            }

            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .tint(.cyan)

            HStack(spacing: 8) {
                Text(progress.currentItem)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let byteText = sessionExportByteText(progress) {
                    Text(byteText)
                        .monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(AstaSans.regular(9))
            .foregroundStyle(MonitorTheme.secondaryText)
        }
        .padding(12)
        .background(
            Color.cyan.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.22), lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(progress.stage.rawValue)
        .accessibilityValue(
            progress.total > 0
                ? "进度 \(Int((progress.fraction * 100).rounded()))%，已完成 \(progress.completed) / \(progress.total)，\(progress.currentItem)"
                : "进度 \(Int((progress.fraction * 100).rounded()))%，已扫描 \(progress.completed) 项，\(progress.currentItem)"
        )
    }

    private var sessionExportCompletedCard: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("导出完成")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(store.lastSessionExportURL?.lastPathComponent ?? "")
                    .font(.system(size: 7.8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            Spacer()
            Button("在 Finder 中显示") { store.revealLastSessionExport() }
                .font(.system(size: 8.5, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)
        }
        .padding(11)
        .background(Color.green.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var sidebarCleanupPendingCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
                .background(Color.orange.opacity(0.10), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text("侧栏残留等待清理")
                    .font(AstaSans.semiBold(10.5))
                Text("\(store.pendingSidebarCleanupCount) 条已删除会话仍有 Codex 项目绑定。请使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop，插件会在退出后自动备份并精确清理。")
                    .font(AstaSans.regular(9))
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            Color.orange.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.20), lineWidth: 0.7)
        }
    }

    private func sessionExportByteText(_ progress: SessionExportProgress) -> String? {
        guard let processed = progress.processedBytes,
              let total = progress.totalBytes,
              total > 0
        else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return "\(formatter.string(fromByteCount: processed)) / \(formatter.string(fromByteCount: total))"
    }

    private var continuitySummaryCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("本地连续性")
                    .font(MonitorTypography.cardTitle)
                Spacer()
                if store.continuitySnapshot.recoverableThreads.isEmpty {
                    Text(continuitySummaryStatus)
                        .font(MonitorTypography.control)
                        .foregroundStyle(continuitySummaryStatusColor)
                } else {
                    Button {
                        focusFirstRecoverableProject()
                    } label: {
                        HStack(spacing: 5) {
                            Text(continuitySummaryStatus)
                            Image(systemName: "arrow.down.to.line")
                                .font(.system(size: 8, weight: .bold))
                        }
                        .font(MonitorTypography.control)
                        .foregroundStyle(continuitySummaryStatusColor)
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(
                            Color.orange.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("定位到第一个包含待恢复会话的项目")
                    .accessibilityHint("展开并滚动到待恢复会话所在项目")
                }
            }
            HStack(spacing: 0) {
                continuityMetric(store.continuitySnapshot.projectCount, "项目")
                continuityMetric(store.continuitySnapshot.sessionCount, "会话")
                continuityMetric(store.continuitySnapshot.archivedCount, "已归档")
                continuityMetric(store.continuitySnapshot.recoverableThreads.count, "待恢复")
            }
            if !store.continuitySnapshot.recoverableThreads.isEmpty {
                Button {
                    confirmsContinuityRecovery = true
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "externaldrive.badge.plus")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                "备份并恢复 \(store.continuitySnapshot.recoverableThreads.count) 条待处理会话"
                            )
                                .font(MonitorTypography.rowTitle)
                            Text("需先完全退出 Codex／ChatGPT；写前备份，不改原始 JSONL，可回滚。")
                                .font(MonitorTypography.metadata)
                                .foregroundStyle(MonitorTheme.secondaryText)
                                .lineLimit(2)
                        }
                        Spacer()
                        if store.isContinuityRecovering { ProgressView().controlSize(.mini).tint(.cyan) }
                    }
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 11)
                    .frame(minHeight: 46)
                    .background(Color.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.isContinuityRecovering)
                .accessibilityHint("操作前需完全退出 Codex 或 ChatGPT；插件会先备份本地索引")
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("导入与迁移")
                        .font(MonitorTypography.rowTitle)
                    Text("支持会话包和完整项目迁移包")
                        .font(MonitorTypography.metadata)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer(minLength: 8)
                Button {
                    store.chooseSessionImportBundle()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "square.and.arrow.down")
                        Text("导入")
                        if store.isSessionImporting {
                            ProgressView().controlSize(.mini).tint(.cyan)
                        }
                    }
                    .font(MonitorTypography.control)
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Color.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(store.isSessionImporting)
                .help("选择并校验 .codexmonitorbundle 或 .codexprojectbundle")
            }
        }
        .padding(MonitorGeometry.cardPadding)
    }

    private var continuitySummaryStatus: String {
        if let progress = store.continuityScanProgress, progress.total > 0 {
            return "正在扫描 \(progress.completed)/\(progress.total)"
        }
        if store.isContinuityLoading { return "正在确认" }
        return store.continuitySnapshot.recoverableThreads.isEmpty ? "记录完整" : "需要处理"
    }

    private var firstRecoverableProjectID: String? {
        let recoverableIDs = Set(
            store.continuitySnapshot.recoverableThreads.map(\.id)
        )
        return store.continuitySnapshot.projectGroups.first { project in
            project.threads.contains { recoverableIDs.contains($0.id) }
        }?.id
    }

    private func recoverableCount(in project: ContinuityProjectGroup) -> Int {
        project.threads.filter(\.canRecover).count
    }

    private func focusFirstRecoverableProject() {
        guard let projectID = firstRecoverableProjectID else { return }
        shouldCenterExpandedContinuityProject = true
        if expandedContinuityProjectID == projectID {
            expandedContinuityProjectID = nil
            DispatchQueue.main.async {
                animate(.islandContentSwap) {
                    expandedContinuityProjectID = projectID
                }
            }
        } else {
            animate(.islandContentSwap) {
                expandedContinuityProjectID = projectID
            }
        }
    }

    private func sessionImportPreviewCard(_ preview: SessionImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("文件完整性校验通过")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
            }

            if preview.codexIsRunning {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("导入前必须完全退出 Codex／ChatGPT Desktop")
                            .font(.system(size: 9, weight: .semibold))
                        Text("使用 Cmd + Q 退出后，点击重新检查。")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.46))
                    }
                    Spacer()
                    Button("重新检查") { store.recheckSelectedSessionImportBundle() }
                        .font(.system(size: 8.5, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                }
                .padding(9)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            HStack(spacing: 0) {
                continuityMetric(preview.sessionCount, "总会话")
                continuityMetric(preview.activeCount, "活动")
                continuityMetric(preview.archivedCount, "已归档")
                continuityMetric(preview.conflictCount, "冲突／残留")
            }

            VStack(alignment: .leading, spacing: 5) {
                importDetailRow("来源账号", value: importSourceAccounts(preview))
                importDetailRow("当前账号", value: store.continuityAccountTitle)
                importDetailRow("来源项目", value: preview.manifest.project.displayName)
                if importHasAccountMismatch(preview) {
                    Label("备份归属与当前账号不同，导入不会改写原始归属记录。", systemImage: "person.crop.circle.badge.exclamationmark")
                        .font(.system(size: 7.8, weight: .semibold))
                        .foregroundStyle(.orange)
                }
            }
            .padding(9)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("导入到")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                Menu {
                    ForEach(store.sessionImportProjectOptions) { option in
                        Button {
                            store.selectSessionImportProject(option)
                        } label: {
                            let suffix = option.isOriginal
                                ? "备份原项目"
                                : (option.isRegistered ? "Codex 项目" : "本地项目")
                            Text("\(option.name) · \(suffix)")
                        }
                    }
                    Divider()
                    Button("选择其他文件夹…") {
                        store.chooseSessionImportProjectDirectory()
                    }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: store.selectedSessionImportProjectOption == nil ? "folder.badge.questionmark" : "folder.fill")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.selectedSessionImportProjectOption?.name ?? "请选择目标 Codex 项目")
                                .font(.system(size: 9, weight: .semibold))
                            Text(store.selectedSessionImportProjectOption?.path ?? preview.manifest.project.originalPath)
                                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.36))
                                .lineLimit(1)
                        }
                        Spacer()
                        if let selected = store.sessionImportMappedProjectURL {
                            Text(FileManager.default.isWritableFile(atPath: selected.path) ? "可写" : "不可写")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(FileManager.default.isWritableFile(atPath: selected.path) ? .green : .orange)
                        }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(store.selectedSessionImportProjectOption == nil ? .orange : .cyan)
                    .padding(.horizontal, 10)
                    .frame(height: 43)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("选择会话导入目标项目")
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("会话身份策略")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                ForEach(SessionImportDuplicateStrategy.allCases, id: \.rawValue) { strategy in
                    Button {
                        store.sessionImportDuplicateStrategy = strategy
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: store.sessionImportDuplicateStrategy == strategy ? "checkmark.circle.fill" : "circle")
                            Text(strategy.title)
                            Spacer()
                        }
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 31)
                        .background(
                            store.sessionImportDuplicateStrategy == strategy
                                ? Color.cyan.opacity(0.14)
                                : Color.white.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.sessionImportDuplicateStrategy == strategy ? .cyan : .white.opacity(0.55))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("会话明细")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                ForEach(Array(preview.manifest.sessions.prefix(5).enumerated()), id: \.element.threadID) { _, session in
                    let conflict = preview.conflicts.first { $0.threadID == session.threadID }
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: session.archived ? "archivebox.fill" : "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(.cyan.opacity(0.8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.title).font(.system(size: 8.5, weight: .semibold)).lineLimit(1)
                            Text(String(session.threadID.prefix(12)) + "… · " + (session.ownershipAlias ?? "归属未知"))
                                .font(.system(size: 7.2, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.34))
                        }
                        Spacer()
                        if let conflict, conflict.hasAnyConflict {
                            Text(conflict.isExistingSession ? "已存在" : "有残留")
                                .font(.system(size: 7.5, weight: .bold))
                                .foregroundStyle(conflict.isExistingSession ? .orange : .yellow)
                        }
                    }
                }
                if preview.sessionCount > 5 {
                    Text("其余 \(preview.sessionCount - 5) 条会话将使用同一策略")
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                }
            }
            .padding(9)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            DisclosureGroup("备份详情") {
                VStack(alignment: .leading, spacing: 4) {
                    importDetailRow("文件", value: preview.bundleURL.lastPathComponent)
                    importDetailRow("格式", value: preview.manifest.format)
                    importDetailRow("条目", value: "\(preview.archiveStatistics.entryCount) 个")
                    importDetailRow("压缩大小", value: ByteCountFormatter.string(fromByteCount: preview.archiveStatistics.archiveBytes, countStyle: .file))
                    importDetailRow("解压大小", value: ByteCountFormatter.string(fromByteCount: preview.archiveStatistics.expandedBytes, countStyle: .file))
                }
                .padding(.top, 5)
            }
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.52))

            HStack(spacing: 7) {
                Button("取消") { store.cancelSessionImport() }
                    .frame(maxWidth: .infinity, minHeight: 37)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .buttonStyle(.plain)
                Button("备份并导入") { store.importSelectedSessionBundle() }
                    .frame(maxWidth: .infinity, minHeight: 37)
                    .background(Color.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan)
                    .disabled(
                        preview.codexIsRunning
                            || !mappedImportDirectoryIsWritable
                    )
            }
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func projectTransferPreviewCard(_ preview: ProjectTransferPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .foregroundStyle(.cyan)
                Text("完整项目迁移包校验通过")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Text("P1")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan)
            }

            if preview.codexIsRunning {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("导入前必须使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop")
                            .font(.system(size: 9, weight: .semibold))
                        Text("退出后点击重新检查，项目文件和会话将作为同一事务导入。")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.46))
                    }
                    Spacer()
                    Button("重新检查") { store.recheckSelectedSessionImportBundle() }
                        .font(.system(size: 8.5, weight: .semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                }
                .padding(9)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }

            HStack(spacing: 0) {
                continuityMetric(preview.fileCount, "项目文件")
                continuityMetric(preview.sessionCount, "Codex 会话")
                continuityMetric(preview.excludedCount, "安全排除")
                continuityMetric(preview.duplicateCount, "重复 ID")
            }

            VStack(alignment: .leading, spacing: 5) {
                importDetailRow("项目", value: preview.manifest.project.displayName)
                importDetailRow("源路径", value: preview.manifest.project.originalPath)
                importDetailRow(
                    "来源账号",
                    value: preview.sourceAccountAliases.isEmpty
                        ? "未记录"
                        : preview.sourceAccountAliases.sorted().joined(separator: "、")
                )
                importDetailRow("当前账号", value: store.continuityAccountTitle)
                importDetailRow(
                    "项目大小",
                    value: ByteCountFormatter.string(
                        fromByteCount: preview.totalProjectBytes,
                        countStyle: .file
                    )
                )
                if let git = preview.manifest.git, git.isRepository {
                    let head = git.head.map { String($0.prefix(8)) } ?? "无 HEAD"
                    importDetailRow(
                        "Git",
                        value: "\(git.branch ?? "detached") · \(head)"
                            + (git.isDirty ? " · dirty" : " · clean")
                    )
                    if let remote = git.remoteURL {
                        importDetailRow("远程", value: remote)
                    }
                    importDetailRow(
                        "未跟踪文件",
                        value: "已包含 \(preview.includedUntrackedFileCount) / \(preview.untrackedFileCount)"
                    )
                } else {
                    importDetailRow("Git", value: "非 Git 项目")
                }
                importDetailRow(
                    "会话附件",
                    value: "已包含 \(preview.includedAttachmentCount) · 缺失 \(preview.missingAttachmentCount)"
                )
            }
            .padding(9)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            Button {
                store.chooseSessionImportProjectDirectory()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: store.projectImportTargetURL == nil
                        ? "folder.badge.questionmark"
                        : "folder.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.projectImportTargetURL == nil
                            ? "选择新目录或空目录"
                            : store.projectImportTargetURL?.lastPathComponent ?? "目标项目")
                            .font(.system(size: 9, weight: .semibold))
                        Text(store.projectImportTargetURL?.path ?? "P0 不会覆盖或合并现有文件")
                            .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.38))
                            .lineLimit(2)
                    }
                    Spacer()
                    if store.projectImportTargetURL != nil {
                        Text(projectImportTargetIsValid ? "空目录" : "不可导入")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(projectImportTargetIsValid ? .green : .orange)
                    }
                    Image(systemName: "chevron.right")
                }
                .foregroundStyle(projectImportTargetIsValid ? .cyan : .orange)
                .padding(.horizontal, 10)
                .frame(minHeight: 43)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("选择完整项目导入目录")

            VStack(alignment: .leading, spacing: 5) {
                Text("会话身份策略")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
                ForEach(SessionImportDuplicateStrategy.allCases, id: \.rawValue) { strategy in
                    Button {
                        store.sessionImportDuplicateStrategy = strategy
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: store.sessionImportDuplicateStrategy == strategy
                                ? "checkmark.circle.fill"
                                : "circle")
                            Text(strategy.title)
                            Spacer()
                        }
                        .font(.system(size: 8.5, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 31)
                        .background(
                            store.sessionImportDuplicateStrategy == strategy
                                ? Color.cyan.opacity(0.14)
                                : Color.white.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(store.sessionImportDuplicateStrategy == strategy
                        ? .cyan
                        : .white.opacity(0.55))
                }
            }

            DisclosureGroup("安全排除和包详情") {
                VStack(alignment: .leading, spacing: 4) {
                    importDetailRow("格式", value: preview.manifest.format)
                    importDetailRow(
                        "压缩大小",
                        value: ByteCountFormatter.string(fromByteCount: preview.archiveBytes, countStyle: .file)
                    )
                    importDetailRow(
                        "解压大小",
                        value: ByteCountFormatter.string(fromByteCount: preview.expandedBytes, countStyle: .file)
                    )
                    ForEach(Array(preview.manifest.excluded.prefix(8).enumerated()), id: \.offset) { _, item in
                        Text("• \(item.relativePath) — \(item.reason)")
                            .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                    }
                    if preview.excludedCount > 8 {
                        Text("其余 \(preview.excludedCount - 8) 项已记录在 Manifest 中")
                            .font(.system(size: 7.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    if preview.manifest.git?.workingTreePatchPath != nil {
                        Label("dirty working tree 已生成 binary-safe patch", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 7.7, weight: .semibold))
                            .foregroundStyle(.cyan.opacity(0.78))
                    }
                    ForEach(Array((preview.manifest.attachments ?? [])
                        .filter { $0.status == .missing }
                        .prefix(5).enumerated()), id: \.offset) { _, attachment in
                        Text("缺失附件：\(attachment.originalPath)")
                            .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.orange.opacity(0.78))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 5)
            }
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.52))

            if let issue = store.projectImportReadinessIssue {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(issue)
                        .font(.system(size: 8.3, weight: .semibold))
                        .foregroundStyle(.orange.opacity(0.92))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 7) {
                Button("取消") { store.cancelSessionImport() }
                    .frame(maxWidth: .infinity, minHeight: 37)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .buttonStyle(.plain)
                Button("备份并导入完整项目") {
                    store.importSelectedProjectBundle()
                }
                .frame(maxWidth: .infinity, minHeight: 37)
                .background(Color.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)
                .disabled(store.isSessionImporting)
            }
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var projectImportTargetIsValid: Bool {
        guard let target = store.projectImportTargetURL,
              FileManager.default.isWritableFile(atPath: target.path),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: target,
                includingPropertiesForKeys: nil
              ) else { return false }
        return contents.allSatisfy { $0.lastPathComponent == ".DS_Store" }
    }

    private func importDetailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.white.opacity(0.36))
            Spacer()
            Text(value)
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.system(size: 8, weight: .medium))
    }

    private func importSourceAccounts(_ preview: SessionImportPreview) -> String {
        let values = Set(preview.manifest.sessions.compactMap(\.ownershipAlias))
        if values.isEmpty { return "未记录" }
        return values.sorted().joined(separator: "、")
    }

    private func importHasAccountMismatch(_ preview: SessionImportPreview) -> Bool {
        let values = Set(preview.manifest.sessions.compactMap(\.ownershipAlias))
        return !values.isEmpty && !values.contains(store.continuityAccountTitle)
    }

    private var mappedImportDirectoryIsWritable: Bool {
        guard let url = store.sessionImportMappedProjectURL else { return false }
        return FileManager.default.isWritableFile(atPath: url.path)
    }

    private func sessionImportProgressCard(_ progress: SessionImportProgress) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                ProgressView().controlSize(.small).tint(.cyan)
                Text(progress.stage.title).font(.system(size: 10, weight: .bold))
                Spacer()
                Text("\(progress.completed) / \(progress.total)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.cyan)
            }
            ProgressView(value: progress.fraction).tint(.cyan)
            if let item = progress.currentItem {
                Text(item).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.42)).lineLimit(1)
            }
            Button(progress.stage == .cancelling ? "正在回滚…" : "取消导入") {
                store.cancelSessionImport()
            }
            .buttonStyle(.plain)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.orange)
            .disabled(progress.stage == .cancelling || progress.stage == .rebuilding || progress.stage == .checkingVisibility)
        }
        .padding(12)
        .background(Color.cyan.opacity(0.065), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var continuitySummaryStatusColor: Color {
        if store.isContinuityLoading { return .cyan }
        return store.continuitySnapshot.recoverableThreads.isEmpty ? .green : .orange
    }

    private func continuityMetric(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(MonitorTypography.secondaryMetric)
                .monospacedDigit()
            Text(label)
                .font(MonitorTypography.metadata)
                .foregroundStyle(.white.opacity(0.38))
        }
        .frame(maxWidth: .infinity)
    }

    private var sessionImportInspectionCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let startedAt = store.sessionImportInspectionStartedAt ?? context.date
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            let dotCount = elapsed % 3 + 1
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text((store.sessionImportInspectionTitle ?? "正在校验备份")
                            + String(repeating: "·", count: dotCount))
                            .font(AstaSans.semiBold(10))
                        Text("已持续 \(elapsed) 秒，正在检查压缩目录、Manifest、校验和与会话记录")
                            .font(AstaSans.regular(8.4))
                            .foregroundStyle(MonitorTheme.tertiaryText)
                    }
                    Spacer(minLength: 8)
                    Button("取消") { store.cancelSessionImport() }
                        .font(AstaSans.semiBold(8.5))
                        .buttonStyle(.plain)
                        .foregroundStyle(.cyan)
                }

                GeometryReader { geometry in
                    let travel = max(0, geometry.size.width - 76)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.12), .cyan, .cyan.opacity(0.12)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: 76, height: 3)
                        .offset(x: travel > 0 ? CGFloat(elapsed % 20) / 19 * travel : 0)
                        .animation(.linear(duration: 1), value: elapsed)
                }
                .frame(height: 3)
                .background(Color.white.opacity(0.055), in: Capsule())
            }
            .padding(12)
            .background(Color.cyan.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.cyan.opacity(0.24), lineWidth: 0.8)
            }
        }
    }

    private func continuityMessageCard(_ message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: color == .orange ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(color)
            Text(message)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.67))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(color.opacity(0.18), lineWidth: 0.7)
        }
    }

    private func continuityStatusMessageColor(_ message: String) -> Color {
        message.hasPrefix("恢复成功") ? .green : .cyan
    }

    private var continuityThreadCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("最近项目会话")
                    .font(MonitorTypography.cardTitle)
                Spacer()
            }
            if store.continuitySnapshot.baselineOwnershipCount > 0 {
                continuityOwnershipEvidence(
                    "归属未知：\(store.continuitySnapshot.baselineOwnershipCount) 条基线前会话",
                    detail: "这些会话早于账号观察基线，无法可靠反推创建账号。"
                )
            } else if store.continuitySnapshot.unknownOwnershipCount > 0 {
                continuityOwnershipEvidence(
                    "归属未知：\(store.continuitySnapshot.unknownOwnershipCount) 条会话",
                    detail: "插件尚未观察到足够证据确认这些会话的账号归属。"
                )
            }
            if store.continuitySnapshot.userThreads.isEmpty {
                Text("暂未发现本地 Codex 会话")
                    .font(MonitorTypography.rowTitle)
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                ForEach(store.continuitySnapshot.projectGroups) { project in
                    continuityProjectSection(project)
                }
            }
        }
        .padding(MonitorGeometry.cardPadding)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
        )
        .onAppear {
            if expandedContinuityProjectID == nil {
                expandedContinuityProjectID = firstRecoverableProjectID
                    ?? store.continuitySnapshot.projectGroups.first?.id
            }
        }
        .onChange(of: store.continuitySnapshot.projectGroups.map(\.id)) { projectIDs in
            if let expandedContinuityProjectID,
               projectIDs.contains(expandedContinuityProjectID) {
                return
            }
            expandedContinuityProjectID = firstRecoverableProjectID
                ?? projectIDs.first
        }
    }

    private func continuityOwnershipEvidence(
        _ title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MonitorTypography.rowTitle)
                    .foregroundStyle(MonitorTheme.secondaryText)
                Text(detail)
                    .font(MonitorTypography.metadata)
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(
            Color.orange.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    private func continuityProjectSection(_ project: ContinuityProjectGroup) -> some View {
        let isExpanded = expandedContinuityProjectID == project.id
        let pendingRecoveryCount = recoverableCount(in: project)
        return VStack(spacing: 5) {
            HStack(spacing: 6) {
                Button {
                    let nextProjectID = isExpanded ? nil : project.id
                    shouldCenterExpandedContinuityProject = nextProjectID != nil
                    animate(.islandContentSwap) {
                        expandedContinuityProjectID = nextProjectID
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.cyan)
                            .frame(width: 18, height: 18)
                            .background(Color.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(project.name)
                            .font(MonitorTypography.cardTitle)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        if pendingRecoveryCount > 0 {
                            Text("\(pendingRecoveryCount) 待恢复")
                                .font(MonitorTypography.metadataMedium)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(
                                    Color.orange.opacity(0.09),
                                    in: Capsule()
                                )
                        }
                        Text(projectConversationCountText(project))
                            .font(MonitorTypography.metadata)
                            .foregroundStyle(MonitorTheme.tertiaryText)
                            .frame(minWidth: 92, alignment: .trailing)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(MonitorTheme.faintText)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity, minHeight: 27)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Menu {
                    Button {
                        store.exportProject(project)
                    } label: {
                        Label("导出项目会话", systemImage: "square.and.arrow.up")
                    }
                    Divider()
                    Button(role: .destructive) {
                        pendingContinuityProjectDeletion = project
                    } label: {
                        Label("删除项目会话", systemImage: "trash")
                    }
                } label: {
                    Group {
                        if store.deletingContinuityProjectID == project.id {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.red)
                        } else {
                            Image(systemName: "ellipsis.circle")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .frame(width: 27, height: 27)
                    .contentShape(Circle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(
                    store.deletingContinuityThreadID != nil
                        || store.deletingContinuityProjectID != nil
                        || store.isSessionExporting
                )
                .help("项目会话操作")
            }

            if isExpanded {
                HStack(alignment: .top, spacing: 9) {
                    Capsule()
                        .fill(Color.cyan.opacity(0.16))
                        .frame(width: 1.5)
                    VStack(spacing: 5) {
                        ForEach(project.threads) { thread in
                            continuityThreadRow(thread)
                        }
                    }
                }
                .padding(.leading, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            pendingRecoveryCount > 0
                ? Color.orange.opacity(0.035)
                : MonitorTheme.subtleCardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.compactRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: MonitorGeometry.compactRadius,
                style: .continuous
            )
            .strokeBorder(
                pendingRecoveryCount > 0
                    ? Color.orange.opacity(0.16)
                    : Color.clear,
                lineWidth: 0.7
            )
        }
        .id(continuityProjectScrollID(project.id))
    }

    private func continuityProjectScrollID(_ projectID: String) -> String {
        "continuity-project-\(projectID)"
    }

    private func continuityThreadRow(_ thread: LocalThreadRecord) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(thread.visibility == .visible ? Color.green : (thread.visibility == .localOnly ? .orange : .red))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(MonitorTypography.rowTitle)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(thread.visibility.title)
                    if thread.isArchived { Text("· 已归档") }
                    Text("·")
                    Text(ownershipTitle(thread.ownership))
                }
                .font(MonitorTypography.metadata)
                .foregroundStyle(MonitorTheme.tertiaryText)
            }
            Spacer(minLength: 6)
            if thread.canRecover {
                Text("待恢复")
                    .font(MonitorTypography.metadataMedium)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .frame(height: 18)
                    .background(Color.orange.opacity(0.09), in: Capsule())
                    .accessibilityLabel("待恢复会话")
            }
            Menu {
                Button {
                    store.exportSession(thread)
                } label: {
                    Label("导出会话", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    pendingContinuityThreadDeletion = thread
                } label: {
                    Label("删除会话", systemImage: "trash")
                }
            } label: {
                Group {
                    if store.deletingContinuityThreadID == thread.id {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(.red)
                    } else {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 10, weight: .semibold))
                    }
                }
                .foregroundStyle(MonitorTheme.tertiaryText)
                .frame(width: 23, height: 23)
                .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(
                store.deletingContinuityThreadID != nil
                    || store.deletingContinuityProjectID != nil
                    || store.isSessionExporting
            )
            .help("会话操作")
        }
        .padding(.vertical, 2)
    }

    private func ownershipTitle(_ ownership: SessionOwnership) -> String {
        switch ownership.confidence {
        case .observed:
            return ownership.accountAlias ?? "已观察账号"
        case .baseline:
            return "基线前未记录"
        case .unknown:
            return "尚未建立归属"
        }
    }

    private func projectDeletionMessage(_ project: ContinuityProjectGroup) -> String {
        let archivedCount = project.threads.filter(\.isArchived).count
        let activeCount = project.threads.count - archivedCount
        return "将通过 Codex App Server 永久删除「\(project.name)」下的 \(project.threads.count) 条会话"
            + "（活动 \(activeCount) 条，已归档 \(archivedCount) 条），并清理 Codex 项目登记。\n\n"
            + "“仅移除 Codex 项目”会保留磁盘目录：\(project.id)\n\n"
            + "“同时移到废纸篓”会把该目录及其中全部文件移入 macOS 废纸篓，可在清空废纸篓前恢复。"
            + "会话删除本身无法撤销；如需保留，请先导出完整项目迁移包。"
    }

    private func projectConversationCountText(_ project: ContinuityProjectGroup) -> String {
        let archivedCount = project.threads.filter(\.isArchived).count
        let activeCount = project.threads.count - archivedCount
        guard archivedCount > 0 else { return "\(activeCount) 个对话" }
        return "\(activeCount) 当前 · \(archivedCount) 归档"
    }

    private var continuityBackupCard: some View {
        HStack(spacing: 9) {
            Image(systemName: "clock.arrow.circlepath")
                .foregroundStyle(.white.opacity(0.55))
            VStack(alignment: .leading, spacing: 2) {
                Text("已保留操作前备份")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(store.lastContinuityBackupURL?.lastPathComponent ?? "")
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }
            Spacer()
            Button("回滚") { confirmsContinuityRollback = true }
                .font(.system(size: 8.5, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
        }
        .padding(11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var sessionImportBackupCard: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.uturn.backward.circle")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("已保留导入前备份")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(store.lastSessionImportBackupURL?.lastPathComponent ?? "")
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }
            Spacer()
            Button("撤销导入") { confirmsSessionImportRollback = true }
                .font(.system(size: 8.5, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .disabled(store.isSessionImporting)
        }
        .padding(11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var projectImportBackupCard: some View {
        HStack(spacing: 9) {
            Image(systemName: "shippingbox.and.arrow.backward")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("已保留完整项目导入前事务")
                    .font(.system(size: 9.5, weight: .semibold))
                Text(store.lastProjectImportBackupURL?.lastPathComponent ?? "")
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }
            Spacer()
            Button("撤销项目导入") { store.rollbackLastProjectImport() }
                .font(.system(size: 8.5, weight: .semibold))
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .disabled(store.isSessionImporting)
        }
        .padding(11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func sessionImportOutcomeCard(_ outcome: SessionImportOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: outcome.requiresRetry ? "exclamationmark.arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                    .foregroundStyle(outcome.requiresRetry ? .orange : .green)
                Text("导入结果")
                    .font(.system(size: 9.5, weight: .bold))
                Spacer()
                Text(outcome.requiresRetry ? "需要确认" : "全部完成")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(outcome.requiresRetry ? .orange : .green)
            }
            importOutcomeRow(
                "会话文件",
                value: "已写入 \(outcome.result.importedCount) 条，跳过 \(outcome.result.skippedDuplicateCount) 条",
                color: .green
            )
            importOutcomeRow(
                "项目绑定",
                value: "新增 \(outcome.result.projectBindingsAdded) 条精确绑定",
                color: .green
            )
            switch outcome.visibility {
            case .notChecked:
                importOutcomeRow("App Server", value: "尚未确认", color: .orange)
            case let .visible(count, expected):
                importOutcomeRow(
                    "App Server",
                    value: "可见 \(count) / \(expected) 条",
                    color: count == expected ? .green : .orange
                )
            case let .rebuildFailed(message):
                importOutcomeRow("App Server", value: "索引重建失败：\(message)", color: .orange)
            }
            if outcome.requiresRetry {
                Button("重试索引确认") { store.retryLastSessionImportVisibilityCheck() }
                    .font(.system(size: 8.5, weight: .semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(.orange)
                    .disabled(store.isSessionImporting)
            }
        }
        .padding(11)
        .background(
            (outcome.requiresRetry ? Color.orange : Color.green).opacity(0.055),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private func importOutcomeRow(_ label: String, value: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(.white.opacity(0.4))
            Spacer()
            Circle().fill(color).frame(width: 4, height: 4)
            Text(value).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 8, weight: .medium))
    }

    private var tiboPage: some View {
        VStack(spacing: 8) {
            tiboTrustConsole
            tiboRadarControls
            Group {
                if let radar = store.tiboRadar {
                    ScrollView(.vertical, showsIndicators: false) {
                    if tiboRadarMode == .live {
                        tiboLiveFeed(radar)
                    } else {
                        tiboTimeline(radar)
                    }
                    }
                } else if store.isTiboFeedLoading {
                    VStack(spacing: 9) {
                        ProgressView().controlSize(.small).tint(.cyan)
                        Text("正在同步蒂博雷达…")
                            .font(AstaSans.medium(9))
                            .foregroundStyle(MonitorTheme.tertiaryText)
                    }
                    .frame(maxWidth: .infinity, minHeight: 130)
                    .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                } else {
                    Text("暂时没有可显示的雷达数据")
                        .font(AstaSans.medium(10))
                        .foregroundStyle(MonitorTheme.tertiaryText)
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .background(MonitorTheme.controlFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
            }
            .opacity(tiboContentOpacity)
            .offset(y: tiboContentOffset)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            store.refreshTiboFeed(ifOlderThan: 60)
            store.refreshNotificationStatus()
        }
        .alert("确认手动重置", isPresented: $confirmsUserQuotaReset) {
            Button("取消", role: .cancel) {
                quotaResetCandidateToConfirm = nil
            }
            Button("记录并通知") {
                if let candidate = quotaResetCandidateToConfirm {
                    store.confirmUserQuotaReset(candidate)
                }
                quotaResetCandidateToConfirm = nil
            }
        } message: {
            if let candidate = quotaResetCandidateToConfirm {
                Text("这会把 \(quotaResetSummary(candidate)) 记录为“手动重置”，并立即发送一次系统通知。")
            }
        }
    }

    private var tiboTrustConsole: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tiboOfficialStatusColor)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("官方额度")
                            .font(MonitorTypography.metadata)
                            .foregroundStyle(MonitorTheme.tertiaryText)
                        Text(tiboOfficialStatusText)
                            .font(MonitorTypography.cardTitle)
                            .foregroundStyle(tiboOfficialStatusColor)
                    }
                }

                Rectangle()
                    .fill(MonitorTheme.separator)
                    .frame(width: 1, height: 26)

                HStack(spacing: 14) {
                    tiboForecastMetric(
                        "24 小时",
                        store.tiboRadar?.forecast.probabilities.rounded24H
                    )
                    tiboForecastMetric(
                        "48 小时",
                        store.tiboRadar?.forecast.probabilities.rounded48H
                    )
                }

                Spacer(minLength: 8)

                HStack(spacing: 6) {
                    Text("社区预测")
                        .foregroundStyle(MonitorTheme.tertiaryText)
                    Circle()
                        .fill(tiboForecastConfidenceColor)
                        .frame(width: 5, height: 5)
                    Text(tiboForecastConfidenceText)
                        .foregroundStyle(tiboForecastConfidenceColor)
                }
                .font(MonitorTypography.metadataMedium)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)

            Divider().overlay(MonitorTheme.hairline)

            HStack(spacing: 8) {
                Label("codex-reset.com", systemImage: "dot.radiowaves.left.and.right")
                    .font(MonitorTypography.metadataMedium)
                    .foregroundStyle(MonitorTheme.secondaryText)
                Text(tiboSourceFreshnessText)
                    .font(MonitorTypography.metadata)
                    .foregroundStyle(
                        tiboSourceIsStale
                            ? Color.orange
                            : MonitorTheme.tertiaryText
                    )
                    .lineLimit(1)

                if store.isTiboFeedLoading {
                    ProgressView().controlSize(.mini).tint(.cyan)
                }

                Spacer(minLength: 8)

                if tiboQuotaHistoryCount > 0 {
                    Button {
                        animate(.islandContentSwap) {
                            showsTiboQuotaHistory.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "clock.arrow.circlepath")
                            Text("恢复记录")
                            Text("\(tiboQuotaHistoryCount)")
                                .monospacedDigit()
                                .foregroundStyle(MonitorTheme.primaryText)
                                .padding(.horizontal, 5)
                                .frame(height: 16)
                                .background(
                                    Color.white.opacity(0.08),
                                    in: Capsule()
                                )
                        }
                        .font(MonitorTypography.control)
                        .foregroundStyle(
                            showsTiboQuotaHistory
                                ? MonitorTheme.cyanAccent
                                : MonitorTheme.secondaryText
                        )
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(
                            showsTiboQuotaHistory
                                ? MonitorTheme.cyanAccent.opacity(0.08)
                                : MonitorTheme.controlFill,
                            in: RoundedRectangle(
                                cornerRadius: 7,
                                style: .continuous
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .popover(
                        isPresented: $showsTiboQuotaHistory,
                        arrowEdge: .bottom
                    ) {
                        tiboQuotaHistoryPanel
                            .frame(width: 460)
                            .background(MonitorTheme.windowBackground)
                            .preferredColorScheme(.dark)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
        }
        .background(MonitorTheme.subtleCardFill, in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("官方额度\(tiboOfficialStatusText)，24 小时预测\(store.tiboRadar?.forecast.probabilities.rounded24H ?? 0)%，48 小时预测\(store.tiboRadar?.forecast.probabilities.rounded48H ?? 0)%")
    }

    private var tiboQuotaHistoryPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(QuotaHistoryFilter.allCases) { filter in
                    Button {
                        animate(.islandContentSwap) { quotaHistoryFilter = filter }
                    } label: {
                        Text(filter.rawValue)
                            .font(AstaSans.semiBold(7.7))
                            .foregroundStyle(
                                quotaHistoryFilter == filter
                                    ? MonitorTheme.primaryText
                                    : MonitorTheme.tertiaryText
                            )
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(
                                quotaHistoryFilter == filter
                                    ? MonitorTheme.selection
                                    : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 8)
                Text(quotaNotificationStatusText)
                    .font(AstaSans.regular(7.5))
                    .foregroundStyle(MonitorTheme.faintText)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Rectangle().fill(MonitorTheme.separator).frame(height: 1)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(store.confirmableQuotaRecoveries.prefix(2).enumerated()), id: \.element.id) { index, candidate in
                        tiboQuotaCandidateRow(candidate)
                        if index < min(store.confirmableQuotaRecoveries.count, 2) - 1
                            || !store.quotaResetEvents.isEmpty {
                            Rectangle().fill(MonitorTheme.separator).frame(height: 1)
                        }
                    }
                    ForEach(Array(filteredQuotaHistory.prefix(8).enumerated()), id: \.element.id) { index, event in
                        tiboQuotaHistoryRow(event)
                        if index < min(filteredQuotaHistory.count, 8) - 1 {
                            Rectangle().fill(MonitorTheme.separator).frame(height: 1)
                        }
                    }
                    if filteredQuotaHistory.isEmpty {
                        Text("该类型暂无恢复记录")
                            .font(AstaSans.regular(8.2))
                            .foregroundStyle(MonitorTheme.faintText)
                            .frame(maxWidth: .infinity, minHeight: 42)
                    }
                }
            }
            .frame(maxHeight: 300)
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
        .background(MonitorTheme.subtleCardFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.065), lineWidth: 0.7)
        }
    }

    private var tiboQuotaHistoryCount: Int {
        store.quotaResetEvents.count + store.confirmableQuotaRecoveries.count
    }

    private var filteredQuotaHistory: [QuotaResetEvent] {
        store.quotaResetEvents.filter { event in
            switch quotaHistoryFilter {
            case .all:
                return true
            case .tibo:
                return event.displayReason == .officialCompleted
                    || event.displayReason == .officialScheduled
                    || event.displayReason == .mixed
            case .natural:
                return event.displayReason == .natural
            case .manual:
                return event.displayReason == .manualCredit
                    || event.displayReason == .userConfirmed
            }
        }
    }

    private func tiboQuotaCandidateRow(_ candidate: QuotaResetConfirmationCandidate) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 14, height: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text("检测到额度恢复，等待确认")
                    .font(AstaSans.semiBold(8.8))
                Text(quotaResetSummary(candidate))
                    .font(AstaSans.regular(8))
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("确认") {
                quotaResetCandidateToConfirm = candidate
                confirmsUserQuotaReset = true
            }
            .buttonStyle(.plain)
            .font(AstaSans.semiBold(8))
            .foregroundStyle(.orange)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color.orange.opacity(0.09), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func tiboQuotaHistoryRow(_ event: QuotaResetEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: quotaResetSymbol(event.displayReason))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(quotaResetColor(event.displayReason))
                .frame(width: 14, height: 15)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.displayReason.title)
                    .font(AstaSans.semiBold(8.8))
                    .foregroundStyle(MonitorTheme.primaryText)
                Text(quotaResetSummary(event))
                    .font(AstaSans.regular(8))
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .lineLimit(1)
                if event.userDisplayType != nil {
                    Text("原始判断：\(event.reason.title)")
                        .font(AstaSans.regular(7.3))
                        .foregroundStyle(MonitorTheme.faintText)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 4) {
                Text(tiboRelativeTime(event.detectedAt))
                    .font(AstaSans.regular(7.5))
                    .foregroundStyle(MonitorTheme.faintText)
                HStack(spacing: 2) {
                    Menu {
                        Button {
                            store.setQuotaResetDisplayType(
                                eventID: event.id,
                                displayType: nil
                            )
                        } label: {
                            if event.userDisplayType == nil {
                                Label("自动判断 · \(event.reason.title)", systemImage: "checkmark")
                            } else {
                                Text("自动判断 · \(event.reason.title)")
                            }
                        }
                        Divider()
                        ForEach(QuotaResetDisplayType.allCases) { type in
                            Button {
                                store.setQuotaResetDisplayType(
                                    eventID: event.id,
                                    displayType: type
                                )
                            } label: {
                                if event.userDisplayType == type
                                    || (event.userDisplayType == nil
                                        && event.reason.defaultDisplayType == type) {
                                    Label(type.title, systemImage: "checkmark")
                                } else {
                                    Text(type.title)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .help("更改显示类型；原始检测证据会保留")
                    if let value = event.sourceURL, let url = URL(string: value) {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 7.5, weight: .semibold))
                                .frame(width: 20, height: 20)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(MonitorTheme.cyanAccent)
                        .help("打开重置证据")
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func tiboForecastMetric(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(MonitorTypography.metadata)
                .foregroundStyle(MonitorTheme.tertiaryText)
            Text(value.map { "\($0)%" } ?? "--")
                .font(MonitorTypography.cardTitle)
                .monospacedDigit()
        }
    }

    private var tiboOfficialStatusText: String {
        switch store.quotaState {
        case .loaded: return "正常"
        case .loading: return "读取中"
        case .failed: return "连接异常"
        }
    }

    private var tiboOfficialStatusColor: Color {
        switch store.quotaState {
        case .loaded: return .green
        case .loading: return .cyan
        case .failed: return .orange
        }
    }

    private var tiboForecastConfidenceText: String {
        switch store.tiboRadar?.forecast.confidence {
        case "high": return "高置信度"
        case "medium": return "中置信度"
        default: return "低置信度"
        }
    }

    private var tiboForecastConfidenceColor: Color {
        switch store.tiboRadar?.forecast.confidence {
        case "high": return .green
        case "medium": return .cyan
        default: return .orange
        }
    }

    private var tiboSourceFreshnessText: String {
        if let error = store.tiboFeedError { return "显示缓存 · \(error)" }
        guard let date = store.tiboRadar?.fetchedDate ?? store.tiboFeedFetchedAt else {
            return "等待数据"
        }
        return "数据 \(tiboRelativeTime(date))"
    }

    private func tiboPinnedSignalRow(
        _ signal: CodexResetRadarSignal,
        radar: CodexResetRadarSnapshot
    ) -> some View {
        let resolution = tiboPinnedSignalResolution(signal, radar: radar)
        let displayEvent = resolution.evidenceEvent ?? resolution.signalEvent
        let displaysFulfillment = resolution.state == .fulfilled
        let displayText = displaysFulfillment
            ? displayEvent?.displayText ?? signal.displayText
            : signal.displayText
        let displayDate = displaysFulfillment
            ? displayEvent?.announcedDate ?? signal.date
            : signal.date
        let statusTitle: String
        let statusColor: Color
        switch resolution.state {
        case .confirmed:
            statusTitle = "已确认重置"
            statusColor = .green
        case .fulfilled:
            statusTitle = "已兑现重置"
            statusColor = .green
        case .activePreview:
            statusTitle = "重置预告 · 等待到达"
            statusColor = .cyan
        case .expired:
            statusTitle = resolution.signalEvent?.preview == true
                ? "重置预告 · 已结束"
                : "重置信号 · 已结束"
            statusColor = .orange
        case .pending:
            statusTitle = "重置信号 · 待确认"
            statusColor = .cyan
        }
        var metadata = ["来源：codex-reset.com"]
        if resolution.isLocallyConfirmed {
            metadata.append("官方额度已验证")
        } else if displaysFulfillment {
            metadata.append("已关联到账证据")
        }
        if let displayEvent {
            metadata.append(tiboTimelineConfidenceLabel(displayEvent))
            metadata.append(tiboTimelineSourceLabel(displayEvent))
        }
        let evidenceURL = displayEvent?.url ?? signal.url
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(AstaSans.semiBold(8.5))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .background(statusColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                Spacer(minLength: 6)
                Text(tiboRelativeTime(displayDate))
                    .font(AstaSans.medium(8))
                    .foregroundStyle(MonitorTheme.faintText)
            }
            Text(tiboHeadline(displayText))
                .font(AstaSans.semiBold(11.5))
                .foregroundStyle(MonitorTheme.primaryText)
                .lineLimit(2)
            if let body = tiboBodyText(displayText) {
                Text(body)
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(2)
            }
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                    .font(.system(size: 8, weight: .medium))
                Text(metadata.joined(separator: " · "))
                Spacer()
                Button {
                    guard let url = URL(string: evidenceURL) else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text(displaysFulfillment ? "查看证据" : "在 X 查看")
                        Image(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(MonitorTheme.cyanAccent)
            }
            .font(AstaSans.medium(8))
            .foregroundStyle(MonitorTheme.faintText)
        }
        .padding(12)
        .background(statusColor.opacity(0.025))
    }

    private func tiboPinnedSignalResolution(
        _ signal: CodexResetRadarSignal,
        radar: CodexResetRadarSnapshot
    ) -> CodexResetPinnedSignalResolution {
        let locallyConfirmedPostIDs: Set<String> = Set(
            store.quotaResetEvents.compactMap { reset -> String? in
                guard reset.reason == .officialCompleted || reset.reason == .mixed else {
                    return nil
                }
                return reset.sourcePostID
            }
        )
        return CodexResetRadarService.resolvePinnedSignal(
            signal,
            timelineEvents: radar.timelineEvents,
            locallyConfirmedPostIDs: locallyConfirmedPostIDs
        )
    }

    private var tiboRadarControls: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("视图")
                    .font(MonitorTypography.metadataMedium)
                    .foregroundStyle(MonitorTheme.tertiaryText)
                HStack(spacing: 3) {
                    ForEach(TiboRadarMode.allCases) { mode in
                        Button {
                            transitionTiboContent {
                                tiboRadarMode = mode
                                tiboRadarFilter = .all
                            }
                        } label: {
                            Text(mode == .live ? "动态" : "时间轴")
                                .font(MonitorTypography.control)
                                .foregroundStyle(
                                    tiboRadarMode == mode
                                        ? MonitorTheme.primaryText
                                        : MonitorTheme.tertiaryText
                                )
                                .animation(
                                    reduceMotion
                                        ? nil
                                        : .easeOut(duration: 0.14),
                                    value: tiboRadarMode
                                )
                                .frame(width: 72, height: 26)
                                .background(
                                    tiboRadarMode == mode
                                        ? Color.white.opacity(0.09)
                                        : Color.clear,
                                    in: RoundedRectangle(
                                        cornerRadius: 7,
                                        style: .continuous
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(
                            tiboRadarMode == mode ? "已选择" : ""
                        )
                    }
                }
                .padding(2)
                .background(
                    MonitorTheme.subtleCardFill,
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("内容")
                    .font(MonitorTypography.metadataMedium)
                    .foregroundStyle(MonitorTheme.tertiaryText)
                HStack(spacing: 2) {
                    ForEach(TiboRadarFilter.allCases) { filter in
                        Button {
                            transitionTiboContent {
                                tiboRadarFilter = filter
                            }
                        } label: {
                            Text(tiboFilterTitle(filter))
                                .font(MonitorTypography.control)
                                .foregroundStyle(
                                    tiboRadarFilter == filter
                                        ? MonitorTheme.primaryText
                                        : MonitorTheme.tertiaryText
                                )
                                .animation(
                                    reduceMotion
                                        ? nil
                                        : .easeOut(duration: 0.12),
                                    value: tiboRadarFilter
                                )
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(
                                    tiboRadarFilter == filter
                                        ? Color.white.opacity(0.07)
                                        : Color.clear,
                                    in: RoundedRectangle(
                                        cornerRadius: 6,
                                        style: .continuous
                                    )
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(
                            tiboRadarFilter == filter ? "已选择" : ""
                        )
                    }
                }
                .padding(2)
                .background(
                    MonitorTheme.subtleCardFill.opacity(0.72),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
            }
        }
    }

    private func transitionTiboContent(_ updates: () -> Void) {
        tiboTransitionGeneration += 1
        let generation = tiboTransitionGeneration
        if reduceMotion {
            updates()
            tiboContentOpacity = 1
            tiboContentOffset = 0
            return
        }

        tiboContentOpacity = 0.35
        tiboContentOffset = 2
        updates()
        DispatchQueue.main.async {
            guard tiboTransitionGeneration == generation else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                tiboContentOpacity = 1
                tiboContentOffset = 0
            }
        }
    }

    private func tiboFilterTitle(_ filter: TiboRadarFilter) -> String {
        switch (tiboRadarMode, filter) {
        case (_, .all): return "全部"
        case (.live, .reset): return "重置信号"
        case (.live, .secondary): return "额度动态"
        case (.timeline, .reset): return "硬重置"
        case (.timeline, .secondary): return "储备重置"
        }
    }

    private func tiboLiveFeed(_ radar: CodexResetRadarSnapshot) -> some View {
        let pinnedResolution = radar.signal.map {
            tiboPinnedSignalResolution($0, radar: radar)
        }
        let pinnedPostIDs = Set([
            radar.signal?.tweetId,
            pinnedResolution?.evidenceEvent?.id,
        ].compactMap { $0 })
        let tweets = radar.tweets.filter { tweet in
            guard !pinnedPostIDs.contains(tweet.id) else { return false }
            switch tiboRadarFilter {
            case .all: return true
            case .reset:
                return tweet.explicitResetClaim == true
                    || tweet.tiboLane == "reset_announcement"
                    || tweet.kind == "signal"
                    || tweet.kind == "candidate"
            case .secondary:
                return tweet.kind == "limits"
                    || (tweet.tiboLane == "reset_related" && tweet.explicitResetClaim != true)
            }
        }
        return LazyVStack(spacing: 0) {
            if let signal = radar.signal, tiboRadarFilter != .secondary {
                tiboPinnedSignalRow(signal, radar: radar)
                if !tweets.isEmpty {
                    Rectangle().fill(MonitorTheme.separator).frame(height: 1)
                }
            }
            ForEach(Array(tweets.prefix(20).enumerated()), id: \.element.id) { index, tweet in
                if index == 0 || !Calendar.current.isDate(
                    tweets[index - 1].date ?? .distantPast,
                    inSameDayAs: tweet.date ?? .distantFuture
                ) {
                    tiboDaySectionHeader(tweet.date)
                }
                tiboTweetRow(tweet, radar: radar)
                if index < min(tweets.count, 20) - 1 {
                    Rectangle().fill(MonitorTheme.separator).frame(height: 1)
                }
            }
        }
        .background(MonitorTheme.subtleCardFill, in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.7)
        }
    }

    private func tiboTweetRow(
        _ tweet: CodexResetRadarTweet,
        radar: CodexResetRadarSnapshot
    ) -> some View {
        let event = radar.timelineEvents.first { $0.id == tweet.id }
        let title = tiboHeadline(tweet.displayText)
        let body = tiboBodyText(tweet.displayText)
        let contentTag = tiboTweetTag(tweet, event: event)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                if let contentTag {
                    Text(contentTag.rawValue)
                        .font(AstaSans.semiBold(8))
                        .foregroundStyle(tiboTweetColor(contentTag))
                        .padding(.horizontal, 7)
                        .frame(height: 21)
                        .background(tiboTweetColor(contentTag).opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(tiboTweetColor(contentTag).opacity(0.35), lineWidth: 0.7)
                        }
                }
                Text(title)
                    .font(AstaSans.semiBold(10.8))
                    .lineLimit(2)
                Spacer()
                Text(tiboRelativeTime(tweet.date))
                    .font(AstaSans.medium(8))
                    .foregroundStyle(MonitorTheme.faintText)
            }
            if let body {
                Text(body)
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(2)
            }
            HStack(spacing: 11) {
                Text("@thsottiaux")
                Text("·")
                Circle()
                    .fill(tiboTweetEvidenceColor(event))
                    .frame(width: 4, height: 4)
                Text(event.map(tiboTimelineSourceLabel) ?? "实时雷达")
                Button {
                    guard let url = URL(string: tweet.url) else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text("X 原文")
                        Image(systemName: "arrow.up.right")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(MonitorTheme.cyanAccent)
                Spacer(minLength: 0)
                tiboEngagement("arrowshape.turn.up.left", tweet.replies)
                tiboEngagement("arrow.2.squarepath", tweet.reposts)
                tiboEngagement("heart", tweet.likes)
            }
            .font(MonitorTypography.metadataMedium)
            .foregroundStyle(MonitorTheme.faintText)
        }
        .padding(12)
    }

    private func tiboDaySectionHeader(_ date: Date?) -> some View {
        HStack(spacing: 8) {
            Text(tiboDaySectionTitle(date))
                .font(AstaSans.semiBold(8.5))
                .foregroundStyle(MonitorTheme.tertiaryText)
            Rectangle()
                .fill(MonitorTheme.separator)
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .frame(height: 22)
    }

    private func tiboDaySectionTitle(_ date: Date?) -> String {
        guard let date else { return "时间未知" }
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func tiboBodyText(_ text: String) -> String? {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder: Substring
        if let stop = compact.firstIndex(of: "。") {
            remainder = compact[compact.index(after: stop)...]
        } else if let range = compact.range(of: ". ") {
            remainder = compact[range.upperBound...]
        } else {
            return nil
        }
        let body = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private func tiboEngagement(_ symbol: String, _ value: Int?) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            Text(tiboCompactCount(value ?? 0))
                .monospacedDigit()
        }
    }

    private func tiboTimeline(_ radar: CodexResetRadarSnapshot) -> some View {
        let events = radar.timelineEvents.filter { event in
            switch tiboRadarFilter {
            case .all: return true
            case .reset: return event.type == "reset" && event.preview == false
            case .secondary: return event.type == "credits"
            }
        }
        let visibleEvents = Array(events.prefix(30))
        return LazyVStack(spacing: 0) {
            ForEach(Array(visibleEvents.enumerated()), id: \.element.id) { index, event in
                tiboTimelineRow(
                    event,
                    isFirst: index == 0,
                    isLast: index == visibleEvents.count - 1,
                    showsDate: index == 0 || visibleEvents[index - 1].date != event.date
                )
            }
        }
        .padding(.vertical, 7)
        .background(MonitorTheme.subtleCardFill, in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.7)
        }
    }

    private func tiboTimelineRow(
        _ event: CodexResetTimelineEvent,
        isFirst: Bool,
        isLast: Bool,
        showsDate: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .trailing, spacing: 2) {
                if showsDate {
                    Text(tiboTimelineDateLabel(event.announcedDate))
                        .font(MonitorTypography.metadataMedium)
                        .foregroundStyle(tiboTimelineColor(event))
                }
                Text(tiboTimelineTimeLabel(event.announcedDate))
                    .font(MonitorTypography.metadata)
                    .foregroundStyle(MonitorTheme.faintText)
            }
            .frame(width: 58, alignment: .trailing)
            .padding(.top, 10)

            ZStack(alignment: .top) {
                GeometryReader { proxy in
                    let centerY: CGFloat = 22
                    if !isFirst {
                        Rectangle()
                            .fill(MonitorTheme.cyanAccent.opacity(0.24))
                            .frame(width: 1, height: centerY)
                            .position(x: proxy.size.width / 2, y: centerY / 2)
                    }
                    if !isLast {
                        Rectangle()
                            .fill(MonitorTheme.cyanAccent.opacity(0.24))
                            .frame(width: 1, height: max(0, proxy.size.height - centerY))
                            .position(
                                x: proxy.size.width / 2,
                                y: centerY + max(0, proxy.size.height - centerY) / 2
                            )
                    }
                }
                ZStack {
                    Circle()
                        .fill(Color(red: 0.075, green: 0.085, blue: 0.095))
                    Circle()
                        .strokeBorder(tiboTimelineColor(event).opacity(0.85), lineWidth: 1.2)
                    Image(systemName: tiboTimelineSymbol(event))
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(tiboTimelineColor(event))
                }
                .frame(width: 22, height: 22)
                .padding(.top, 11)
            }
            .frame(width: 38)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(tiboTimelineTitle(event))
                        .font(AstaSans.semiBold(10.5))
                    Text(tiboTimelineConfidenceLabel(event))
                        .font(MonitorTypography.metadataMedium)
                        .foregroundStyle(tiboTimelineColor(event))
                    if let status = event.resetVerificationStatus {
                        Text(tiboVerificationLabel(status))
                            .font(MonitorTypography.metadataMedium)
                            .foregroundStyle(MonitorTheme.secondaryText)
                    }
                    Spacer()
                    Text(tiboRelativeTime(event.announcedDate))
                        .font(MonitorTypography.metadata)
                        .foregroundStyle(MonitorTheme.faintText)
                }
                Text(event.displayText)
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(3)
                HStack(spacing: 7) {
                    Text(tiboTimelineSourceLabel(event))
                    Button {
                        guard let url = URL(string: event.url) else { return }
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack(spacing: 4) {
                            Text("查看 X 证据")
                            Image(systemName: "arrow.up.right")
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MonitorTheme.cyanAccent)
                    Spacer()
                }
                .font(MonitorTypography.metadataMedium)
                .foregroundStyle(MonitorTheme.faintText)
            }
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tiboTimelineDateLabel(_ date: Date?) -> String {
        guard let date else { return "--" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func tiboTimelineTimeLabel(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    private func tiboTweetTag(
        _ tweet: CodexResetRadarTweet,
        event: CodexResetTimelineEvent?
    ) -> CodexResetContentTag? {
        CodexResetRadarPresentation.contentTag(
            tweetKind: tweet.kind,
            explicitResetClaim: tweet.explicitResetClaim == true,
            eventType: event?.type,
            eventPreview: event?.preview == true,
            eventSource: event?.source,
            eventConfidence: event?.confidence
        )
    }

    private func tiboTweetColor(_ tag: CodexResetContentTag) -> Color {
        switch tag {
        case .limit, .banked: return .orange
        case .fulfilled: return .green
        case .reset, .preview: return .cyan
        }
    }

    private func tiboTweetEvidenceColor(_ event: CodexResetTimelineEvent?) -> Color {
        guard let event else { return MonitorTheme.faintText }
        if event.source == "archive", event.confidence == "high" { return .green }
        if event.source == "archive" { return .cyan }
        return MonitorTheme.faintText
    }

    private func tiboTimelineTitle(_ event: CodexResetTimelineEvent) -> String {
        if event.resetVerificationStatus == "rejected" { return "候选信号已驳回" }
        if event.type == "credits" { return "储备重置" }
        if event.preview { return "重置预告" }
        if event.type == "reset" { return "额度重置" }
        if event.type == "promo" || event.type == "boost" { return "额度促销动态" }
        return "相关动态"
    }

    private func tiboTimelineSymbol(_ event: CodexResetTimelineEvent) -> String {
        if event.resetVerificationStatus == "rejected" { return "xmark" }
        if event.type == "credits" { return "tray.full.fill" }
        if event.preview { return "clock.fill" }
        if event.type == "reset" { return "checkmark" }
        return "bolt.fill"
    }

    private func tiboTimelineColor(_ event: CodexResetTimelineEvent) -> Color {
        if event.resetVerificationStatus == "rejected" { return .red }
        if event.type == "credits" { return .orange }
        if event.preview || event.confidence == "medium" { return .cyan }
        if event.type == "reset", event.confidence == "high" { return .green }
        return MonitorTheme.secondaryText
    }

    private func tiboTimelineConfidenceLabel(_ event: CodexResetTimelineEvent) -> String {
        switch event.confidence {
        case "high": return "高置信度"
        case "medium": return "中置信度"
        default: return "低置信度"
        }
    }

    private func tiboTimelineSourceLabel(_ event: CodexResetTimelineEvent) -> String {
        event.source == "archive" ? "已归档证据" : "实时雷达"
    }

    private func tiboVerificationLabel(_ value: String) -> String {
        switch value {
        case "pending": return "待验证"
        case "rejected": return "已驳回"
        case "expired": return "验证窗口已结束"
        default: return value
        }
    }

    private func tiboHeadline(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stop = compact.firstIndex(of: "。") {
            let sentence = String(compact[...stop])
            if sentence.count <= 58 { return sentence }
        }
        return compact.count <= 58 ? compact : String(compact.prefix(58)) + "…"
    }

    private func tiboCompactCount(_ value: Int) -> String {
        if value >= 10_000 { return String(format: "%.1f万", Double(value) / 10_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private var quotaResetHistoryCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text("额度恢复监控")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                quotaNotificationStatusControl
            }

            ForEach(store.confirmableQuotaRecoveries.prefix(2)) { candidate in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.orange)
                        .frame(width: 13, height: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("检测到额度恢复，等待确认")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text(quotaResetSummary(candidate))
                            .font(.system(size: 8.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.46))
                            .lineLimit(2)
                    }
                    Spacer(minLength: 4)
                    Button("确认手动重置") {
                        quotaResetCandidateToConfirm = candidate
                        confirmsUserQuotaReset = true
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.92))
                    .padding(.horizontal, 7)
                    .frame(minHeight: 22)
                    .background(.orange.opacity(0.10), in: Capsule())
                }
            }

            if store.quotaResetEvents.isEmpty && store.confirmableQuotaRecoveries.isEmpty {
                Text("正在监控 Tibo 重置与窗口到期重置")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            } else {
                ForEach(store.quotaResetEvents.prefix(3)) { event in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: quotaResetSymbol(event.displayReason))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(quotaResetColor(event.displayReason))
                            .frame(width: 13, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.displayReason.title)
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(quotaResetSummary(event))
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.46))
                                .lineLimit(2)
                        }
                        Spacer(minLength: 4)
                        Text(tiboRelativeTime(event.detectedAt))
                            .font(.system(size: 7.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.30))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard let value = event.sourceURL, let url = URL(string: value) else { return }
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.cyan.opacity(0.09), lineWidth: 0.7)
        }
        .onAppear {
            store.refreshNotificationStatus()
        }
    }

    @ViewBuilder
    private var quotaNotificationStatusControl: some View {
        if store.quotaNotificationStatus == .denied {
            Button {
                store.openNotificationSettings()
            } label: {
                HStack(spacing: 4) {
                    Text("打开通知设置")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 7, weight: .bold))
                }
                .font(.system(size: 8, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.orange.opacity(0.92))
                .padding(.horizontal, 9)
                .frame(minWidth: 88, minHeight: 28)
                .background(Color.orange.opacity(0.09), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Color.orange.opacity(0.24), lineWidth: 0.7)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("前往系统设置，为 Codex Monitor 开启通知")
        } else {
            Text(quotaNotificationStatusText)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.34))
        }
    }

    private var quotaNotificationStatusText: String {
        switch store.quotaNotificationStatus {
        case .unknown: return "等待通知授权"
        case .enabled: return "系统通知已开启"
        case .denied: return "通知已关闭"
        }
    }

    private func quotaResetSummary(_ event: QuotaResetEvent) -> String {
        event.changes.map { change in
            "\(change.bucketName) \(change.windowLabel) \(change.previousRemainingPercent)% → \(change.currentRemainingPercent)%"
        }.joined(separator: " · ")
    }

    private func quotaResetSummary(_ candidate: QuotaResetConfirmationCandidate) -> String {
        candidate.changes.map { change in
            "\(change.bucketName) \(change.windowLabel) \(change.previousRemainingPercent)% → \(change.currentRemainingPercent)%"
        }.joined(separator: " · ")
    }

    private func quotaResetSymbol(_ reason: QuotaResetReason) -> String {
        switch reason {
        case .officialCompleted: return "bolt.fill"
        case .officialScheduled: return "calendar.badge.checkmark"
        case .natural: return "clock.arrow.circlepath"
        case .mixed: return "checkmark.seal.fill"
        case .manualCredit: return "creditcard.and.123"
        case .userConfirmed: return "person.crop.circle.badge.checkmark"
        case .unverified: return "questionmark.circle.fill"
        }
    }

    private func quotaResetColor(_ reason: QuotaResetReason) -> Color {
        switch reason {
        case .officialCompleted: return .green
        case .officialScheduled: return .cyan
        case .natural: return .blue
        case .mixed: return .mint
        case .manualCredit: return .orange
        case .userConfirmed: return .orange
        case .unverified: return .gray
        }
    }

    private var tiboSourceCard: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.12))
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.88))
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text("Tibo 的 Codex 动态")
                        .font(.system(size: 11, weight: .semibold))
                    Text("@thsottiaux")
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.35))
                }
                Text(tiboSourceSubtitle)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(tiboSourceIsStale ? .orange.opacity(0.82) : .white.opacity(0.4))
                    .lineLimit(1)
            }

            Spacer(minLength: 5)
            if store.isTiboFeedLoading {
                ProgressView().controlSize(.mini).tint(.cyan)
            } else {
                Button { store.refreshTiboFeed() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.46))
            }
        }
        .padding(11)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func tiboEventCard(_ item: TiboDisplayEvent) -> some View {
        let event = item.event
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: tiboEventSymbol(event.kind))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tiboEventColor(event.kind))
                Text(item.isManualCompletion ? "已确认额度重置" : tiboEventTitle(event.kind))
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer()
                Text(tiboRelativeTime(event.announcedDate))
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
            }

            Text(event.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.leading)
                .lineSpacing(2)
                .lineLimit(5)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !item.supportingSchedules.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill")
                    Text("由 \(item.supportingSchedules.count) 条计划动态确认")
                }
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.green.opacity(0.72))
            }

            tiboTranslationBlock(for: event)

            HStack(spacing: 5) {
                if let effective = event.effectiveDate, event.kind == .resetScheduled {
                    Image(systemName: "clock")
                    Text("预计 \(tiboAbsoluteTime(effective))")
                } else {
                    Text("置信度 \(Int((event.confidence * 100).rounded()))%")
                }
                Spacer()
                Button {
                    guard let url = URL(string: event.source.url) else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 4) {
                        Text("在 X 查看")
                        Image(systemName: "arrow.up.right")
                    }
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("打开 @thsottiaux 的原始动态")
            }
            .font(.system(size: 8, weight: .semibold, design: .rounded))
            .foregroundStyle(.cyan.opacity(0.68))
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(tiboEventColor(event.kind).opacity(0.10), lineWidth: 0.7)
        }
    }

    @ViewBuilder
    private func tiboTranslationBlock(for event: TiboEvent) -> some View {
#if canImport(Translation)
        if #available(macOS 15.0, *) {
            TiboChineseTranslationView(
                postID: event.source.postId,
                sourceText: event.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        } else {
            HStack(spacing: 5) {
                Image(systemName: "character.book.closed")
                Text("中文翻译需要 macOS 15 或更高版本")
            }
            .font(.system(size: 8, weight: .medium))
            .foregroundStyle(.white.opacity(0.30))
        }
#else
        HStack(spacing: 5) {
            Image(systemName: "character.book.closed")
            Text("当前系统不支持本地翻译")
        }
        .font(.system(size: 8, weight: .medium))
        .foregroundStyle(.white.opacity(0.30))
#endif
    }

    private var tiboSourceIsStale: Bool {
        guard let date = store.tiboRadar?.fetchedDate
                ?? store.tiboFeedFetchedAt else { return store.tiboFeedError != nil }
        return store.tiboRadar?.stale == true
            || Date().timeIntervalSince(date) > CodexResetRadarService.staleInterval
    }

    private var tiboSourceSubtitle: String {
        if let error = store.tiboFeedError {
            return store.tiboFeed == nil ? error : "显示上次数据 · \(error)"
        }
        guard let date = store.tiboFeed?.lastSuccessfulCheckDate
                ?? store.tiboFeed?.generatedDate else { return "非官方数据" }
        let prefix = tiboSourceIsStale ? "数据可能延迟" : "最近检查"
        return "\(prefix) \(tiboRelativeTime(date))"
    }

    private func tiboEventTitle(_ kind: TiboEventKind) -> String {
        switch kind {
        case .resetCompleted: return "已完成额度重置"
        case .resetScheduled: return "计划重置额度"
        case .bankedReset: return "已预留额度重置"
        case .limitIncrease: return "额度已提升"
        case .uncertain: return "发现相关动态"
        }
    }

    private func tiboEventSymbol(_ kind: TiboEventKind) -> String {
        switch kind {
        case .resetCompleted: return "bolt.fill"
        case .resetScheduled: return "calendar.badge.clock"
        case .bankedReset: return "tray.full.fill"
        case .limitIncrease: return "arrow.up.right.circle.fill"
        case .uncertain: return "questionmark.circle.fill"
        }
    }

    private func tiboEventColor(_ kind: TiboEventKind) -> Color {
        switch kind {
        case .resetCompleted: return .green
        case .resetScheduled: return .cyan
        case .bankedReset: return .orange
        case .limitIncrease: return .purple
        case .uncertain: return .gray
        }
    }

    private func tiboRelativeTime(_ date: Date?) -> String {
        guard let date else { return "时间未知" }
        let seconds = max(0, Date().timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600)) 小时前" }
        return "\(Int(seconds / 86_400)) 天前"
    }

    private func tiboAbsoluteTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "M 月 d 日 HH:mm"
        return formatter.string(from: date)
    }

    private var costOverviewCard: some View {
        let totals = selectedCost
        return VStack(alignment: .leading, spacing: MonitorGeometry.overviewItemGap) {
            dataCardHeader(
                symbol: "chart.xyaxis.line",
                title: "成本概览"
            ) { Text("跟随统计周期 · \(costPeriod.rawValue)") }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(costPeriodTitle)
                        .font(AstaSans.regular(10.5))
                        .foregroundStyle(MonitorTheme.secondaryText)
                    Text(formatDollars(totals.dollars))
                        .font(MonitorTypography.primaryMetric)
                        .tracking(-0.21)
                        .foregroundStyle(MonitorTheme.cyanAccent)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Token 吞吐量")
                        .font(MonitorTypography.metadata)
                        .foregroundStyle(.white.opacity(0.36))
                    Text(formatTokens(totals.tokens))
                        .font(MonitorTypography.secondaryMetric)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }

            HStack(spacing: 8) {
                Text("输入 \(formatCompactTokens(totals.inputTokens))")
                Text("输出 \(formatCompactTokens(totals.outputTokens))")
                Text("缓存 \(formatCompactTokens(totals.cacheTokens))")
                Spacer(minLength: 0)
                if store.isCostLoading { ProgressView().controlSize(.mini).tint(.cyan) }
            }
            .font(AstaSans.regular(10.5))
            .foregroundStyle(MonitorTheme.tertiaryText)
            .lineLimit(1)

            CostTrendChart(
                values: Array(selectedCost.series.prefix(costVisiblePointCount)),
                period: costPeriod
            )
            .frame(height: MonitorGeometry.chartHeight)

            HStack {
                Text(costTrendStartLabel)
                Spacer()
                Text(costTrendEndLabel)
            }
            .font(MonitorTypography.body)
            .foregroundStyle(MonitorTheme.faintText)
        }
        .padding(MonitorGeometry.cardPadding)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: totals.dollars)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: totals.tokens)
    }

    private var costActivityCard: some View {
        VStack(alignment: .leading, spacing: MonitorGeometry.overviewItemGap) {
            dataCardHeader(
                symbol: "square.grid.3x3.fill",
                title: "成本活动"
            ) {
                AnalysisActivityRangeMenu(selection: $costActivityPeriod)
            }

            if !selectedCostScope.usage.activityIsReady {
                Text("正在整理成本活动…")
                    .font(AstaSans.regular(10.5))
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                CostActivityHeatmap(
                    activity: selectedCostActivity,
                    reduceMotion: reduceMotion
                )
            }
        }
        .padding(MonitorGeometry.cardPadding)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: costActivityPeriod)
    }

    private var providerCostCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            dataCardHeader(
                symbol: "doc.text.fill",
                title: "日志来源"
            ) {
                HStack(spacing: 6) {
                    Text("跟随统计周期 · \(costPeriod.rawValue)")
                    if store.isCostLoading { ProgressView().controlSize(.mini).tint(.cyan) }
                }
            }
            ForEach(selectedCostScope.providers) { provider in
                let totals = provider.totals(for: costPeriod)
                VStack(spacing: 4) {
                    HStack {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 6, height: 6)
                        Text(provider.provider.rawValue)
                            .font(MonitorTypography.cardTitle)
                        Spacer()
                    }
                    HStack {
                        if totals.tokens == 0 {
                            Text("暂无 Codex 本地日志")
                                .foregroundStyle(.white.opacity(0.42))
                        } else {
                            Text("Token 吞吐量")
                                .foregroundStyle(.white.opacity(0.42))
                            Text(formatTokens(totals.tokens))
                                .foregroundStyle(.cyan.opacity(0.78))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                            Spacer()
                            Text("等价成本")
                                .foregroundStyle(.white.opacity(0.42))
                            Text(formatDollars(totals.dollars))
                                .fontWeight(.bold)
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                    .font(MonitorTypography.body)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                }
            }
            if !selectedCostScope.unknownModels.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8))
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(selectedCostScope.unknownModels.count) 个未定价模型未计入美元估值")
                        Text(selectedCostScope.unknownModels.joined(separator: ", "))
                            .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.orange.opacity(0.82))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !selectedCostScope.estimatedModelAliases.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(selectedCostScope.estimatedModelAliases.keys.sorted(), id: \.self) { model in
                        if let billingModel = selectedCostScope.estimatedModelAliases[model] {
                            HStack(spacing: 5) {
                                Image(systemName: "equal.circle.fill")
                                    .font(.system(size: 8))
                                Text("\(model) 已按 \(billingModel) 估算")
                                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .foregroundStyle(.cyan.opacity(0.68))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(MonitorGeometry.cardPadding)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
        )
    }

    private var analysisAccountScopeBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label("数据范围", systemImage: "person.2.fill")
                    .font(MonitorTypography.cardTitle)
                    .foregroundStyle(MonitorTheme.secondaryText)
                Spacer(minLength: 8)
                accountScopeMenu
            }

            HStack(spacing: 8) {
                Text(accountScopeEvidenceText)
                    .font(MonitorTypography.metadata)
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if shouldOfferMonthlyHistoryShortcut {
                    Button("查看近 30 日") {
                        animate(.islandContentSwap) {
                            usagePeriod = .month
                            costPeriod = .month
                        }
                    }
                    .buttonStyle(.plain)
                    .font(MonitorTypography.control)
                    .foregroundStyle(MonitorTheme.cyanAccent)
                }
            }

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            MonitorTheme.subtleCardFill,
            in: RoundedRectangle(
                cornerRadius: MonitorGeometry.cardRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: MonitorGeometry.cardRadius,
                style: .continuous
            )
            .strokeBorder(MonitorTheme.hairline, lineWidth: 0.5)
        }
    }

    private var analysisPeriodBar: some View {
        HStack(spacing: 12) {
            Label("统计周期", systemImage: "calendar")
                .font(MonitorTypography.cardTitle)
                .foregroundStyle(MonitorTheme.secondaryText)
            Spacer(minLength: 8)
            analysisPeriodControl
                .frame(maxWidth: 360)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            MonitorTheme.subtleCardFill,
            in: RoundedRectangle(
                cornerRadius: MonitorGeometry.cardRadius,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: MonitorGeometry.cardRadius,
                style: .continuous
            )
            .strokeBorder(MonitorTheme.hairline, lineWidth: 0.5)
        }
    }

    private var accountScopeMenu: some View {
        Menu {
            accountScopeButton(id: UsageAccountScope.all, title: "全部账号")
            Divider()
            ForEach(store.usageAccountOptions) { account in
                accountScopeButton(
                    id: account.id,
                    title: accountScopeTitle(account)
                )
            }
            Divider()
            accountScopeButton(id: UsageAccountScope.unknown, title: "归属未知")
        } label: {
            HStack(spacing: 6) {
                Text(selectedAccountScopeTitle)
                    .font(MonitorTypography.controlLarge)
                    .foregroundStyle(MonitorTheme.primaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(minWidth: 150, minHeight: 26, alignment: .trailing)
            .background(
                MonitorTheme.controlFill,
                in: RoundedRectangle(
                    cornerRadius: MonitorTheme.controlCornerRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("筛选 Usage 和 Cost 的本地历史统计范围")
        .accessibilityLabel("数据范围")
        .accessibilityValue(selectedAccountScopeTitle)
    }

    @ViewBuilder
    private var analysisPeriodControl: some View {
        if expandedPage == .usage {
            HStack(spacing: 3) {
                ForEach(UsageTrendPeriod.allCases) { period in
                    Button {
                        animate(.islandContentSwap) { usagePeriod = period }
                    } label: {
                        Text(period.rawValue)
                            .font(MonitorTypography.controlLarge)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .foregroundStyle(
                                usagePeriod == period
                                    ? MonitorTheme.primaryText
                                    : MonitorTheme.tertiaryText
                            )
                            .background(
                                usagePeriod == period
                                    ? Color.white.opacity(0.11)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(usagePeriod == period ? "已选择" : "")
                }
            }
            .padding(3)
            .background(
                MonitorTheme.controlFill,
                in: RoundedRectangle(
                    cornerRadius: MonitorTheme.controlCornerRadius,
                    style: .continuous
                )
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("统计周期")
        } else {
            HStack(spacing: 3) {
                ForEach(UsagePeriod.allCases) { period in
                    Button {
                        animate(.islandContentSwap) { costPeriod = period }
                    } label: {
                        Text(period.rawValue)
                            .font(MonitorTypography.controlLarge)
                            .frame(maxWidth: .infinity, minHeight: 24)
                            .foregroundStyle(
                                costPeriod == period
                                    ? MonitorTheme.primaryText
                                    : MonitorTheme.tertiaryText
                            )
                            .background(
                                costPeriod == period
                                    ? Color.white.opacity(0.11)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(costPeriod == period ? "已选择" : "")
                }
            }
            .padding(3)
            .background(
                MonitorTheme.controlFill,
                in: RoundedRectangle(
                    cornerRadius: MonitorTheme.controlCornerRadius,
                    style: .continuous
                )
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("统计周期")
        }
    }

    private func accountScopeButton(id: String, title: String) -> some View {
        Button {
            animate(.islandContentSwap) { usageAccountScopeID = id }
        } label: {
            if usageAccountScopeID == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var selectedAccountScopeTitle: String {
        if usageAccountScopeID == UsageAccountScope.all { return "全部账号" }
        if usageAccountScopeID == UsageAccountScope.unknown { return "归属未知" }
        guard let account = store.usageAccountOptions.first(where: { $0.id == usageAccountScopeID })
        else { return "全部账号" }
        return accountScopeTitle(account)
    }

    private func accountScopeTitle(_ account: UsageAccountOption) -> String {
        let summary = account.emailSummary ?? "邮箱待记录"
        return "\(account.alias) · \(summary)" + (account.isCurrent ? "（当前）" : "")
    }

    private var accountScopeEvidenceText: String {
        if usageAccountScopeID == UsageAccountScope.all {
            return "综合统计包含归属未知的基线前记录"
        }
        if usageAccountScopeID == UsageAccountScope.unknown {
            return "仅显示基线前或尚无可靠账号归属的记录"
        }
        if shouldOfferMonthlyHistoryShortcut {
            return "\(selectedPageEmptyHistoryTitle) · 近 30 日 \(formatCompactTokens(selectedCostScope.usage.month.tokens))"
        }
        if selectedCostScope.usage.month.tokens == 0,
           store.costSnapshot.unknownAccount.usage.month.tokens > 0 {
            return "暂无可靠归属记录 · 未归属历史 \(formatCompactTokens(store.costSnapshot.unknownAccount.usage.month.tokens))"
        }
        return "仅显示插件可靠观察到归属该账号的会话"
    }

    private var selectedPageEmptyHistoryTitle: String {
        if expandedPage == .cost { return costPeriod.emptyActivityTitle }
        return usagePeriod.emptyHistoryTitle
    }

    private var shouldOfferMonthlyHistoryShortcut: Bool {
        guard usageAccountScopeID != UsageAccountScope.all,
              usageAccountScopeID != UsageAccountScope.unknown
        else { return false }
        if expandedPage == .cost {
            guard costPeriod != .month else { return false }
            return selectedCostScope.usage.totals(for: costPeriod).tokens == 0
                && selectedCostScope.usage.month.tokens > 0
        }
        guard usagePeriod != .month else { return false }
        return selectedCostScope.usage.totals(for: usagePeriod).tokens == 0
            && selectedCostScope.usage.month.tokens > 0
    }

    private func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB tokens", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM tokens", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK tokens", Double(value) / 1_000) }
        return "\(value) tokens"
    }

    private func formatDollars(_ value: Double) -> String {
        value < 10 ? String(format: "$%.2f", value) : String(format: "$%.1f", value)
    }

    private var selectedCost: CostTotals {
        selectedCostScope.totals(for: costPeriod)
    }

    private var selectedCostScope: CostScopeSnapshot {
        store.costSnapshot.scope(for: usageAccountScopeID)
    }

    private var selectedCostActivity: [DailyCostActivity] {
        Array(selectedCostScope.costActivity.suffix(costActivityPeriod.dayCount))
    }

    private var costPeriodTitle: String {
        switch costPeriod {
        case .day: return "今日 API 等价成本"
        case .week: return "近 7 日 API 等价成本"
        case .month: return "近 30 日 API 等价成本"
        }
    }

    private var costVisiblePointCount: Int {
        let calendar = Calendar.current
        switch costPeriod {
        case .day:
            return min(selectedCost.series.count, calendar.component(.hour, from: Date()) + 1)
        case .week:
            return min(selectedCost.series.count, 7)
        case .month:
            return min(selectedCost.series.count, 30)
        }
    }

    private var costTrendStartLabel: String {
        switch costPeriod {
        case .day: return "00 时"
        case .week: return rollingDateLabel(daysAgo: 6)
        case .month: return rollingDateLabel(daysAgo: 29)
        }
    }

    private var costTrendEndLabel: String {
        switch costPeriod {
        case .day: return "23 时"
        case .week, .month: return rollingDateLabel(daysAgo: 0)
        }
    }

    private var selectedUsage: UsageTotals {
        selectedCostScope.usage.totals(for: usagePeriod)
    }

    private var selectedTokenActivity: [DailyTokenActivity] {
        Array(selectedCostScope.usage.activity.suffix(usageActivityPeriod.dayCount))
    }

    private func dataCardHeader<Trailing: View>(
        symbol: String,
        title: String,
        badge: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(MonitorTheme.cyanAccent)
                .frame(width: 12)
            Text(title)
                .font(MonitorTypography.cardTitle)
                .foregroundStyle(MonitorTheme.primaryText)
            if let badge {
                Text(badge)
                    .font(.system(size: 7, weight: .bold, design: .rounded))
                    .tracking(0.35)
                    .foregroundStyle(MonitorTheme.cyanAccent)
                    .padding(.horizontal, 6)
                    .frame(height: 15)
                    .background(MonitorTheme.cyanAccent.opacity(0.09), in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(MonitorTheme.cyanAccent.opacity(0.15), lineWidth: 0.5)
                    }
            }
            Spacer(minLength: 8)
            trailing()
                .font(MonitorTypography.metadata)
                .foregroundStyle(MonitorTheme.faintText)
                .lineLimit(1)
        }
        .frame(minHeight: 18)
    }

    private var usageOverviewCard: some View {
        let usage = selectedUsage
        return VStack(alignment: .leading, spacing: MonitorGeometry.overviewItemGap) {
            dataCardHeader(
                symbol: "chart.xyaxis.line",
                title: "Token 概览"
            ) { Text("跟随统计周期 · \(usagePeriod.rawValue)") }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(usagePeriodTitle)
                        .font(AstaSans.regular(10.5))
                        .foregroundStyle(MonitorTheme.secondaryText)
                    Text(formatTokens(usage.tokens))
                        .font(AstaSans.semiBold(21))
                        .tracking(-0.21)
                        .foregroundStyle(MonitorTheme.cyanAccent)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                Spacer()
                UsageCountMetric(value: usage.sessionCount, label: "会话")
                UsageCountMetric(value: usage.projectCount, label: "项目")
            }

            HStack(spacing: 8) {
                Text("输入 \(formatCompactTokens(usage.inputTokens))")
                Text("输出 \(formatCompactTokens(usage.outputTokens))")
                Text("缓存 \(formatCompactTokens(usage.cacheTokens))")
                Spacer(minLength: 0)
                if store.isCostLoading { ProgressView().controlSize(.mini).tint(.cyan) }
            }
            .font(AstaSans.regular(10.5))
            .foregroundStyle(MonitorTheme.tertiaryText)
            .lineLimit(1)

            UsageTrendChart(
                values: Array(usage.series.prefix(usageVisiblePointCount)),
                period: usagePeriod
            )
            .frame(height: 58)

            HStack {
                Text(usageTrendStartLabel)
                Spacer()
                Text(usageTrendEndLabel)
            }
            .font(AstaSans.regular(9))
            .foregroundStyle(MonitorTheme.faintText)
        }
        .padding(MonitorGeometry.cardPadding)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: usage.tokens)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: usage.sessionCount)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: usage.projectCount)
    }

    private var usageActivityCard: some View {
        VStack(alignment: .leading, spacing: MonitorGeometry.overviewItemGap) {
            dataCardHeader(
                symbol: "square.grid.3x3.fill",
                title: "Token 活动"
            ) {
                AnalysisActivityRangeMenu(selection: $usageActivityPeriod)
            }

            if !selectedCostScope.usage.activityIsReady {
                Text("正在整理 Token 活动…")
                    .font(AstaSans.regular(10.5))
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .frame(maxWidth: .infinity, minHeight: 48)
            } else {
                TokenActivityHeatmap(
                    activity: selectedTokenActivity,
                    reduceMotion: reduceMotion
                )
            }
        }
        .padding(MonitorGeometry.cardPadding)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: usageActivityPeriod)
    }

    private var usageProjectCard: some View {
        let usage = selectedUsage
        let topProjects = Array(usage.projects.prefix(4))
        return VStack(alignment: .leading, spacing: 8) {
            dataCardHeader(
                symbol: "folder.fill",
                title: "项目用量"
            ) { Text("跟随统计周期 · \(usagePeriod.rawValue)") }
            if topProjects.isEmpty {
                Text("当前周期暂无本地 Token 记录")
                    .font(AstaSans.regular(10.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            } else {
                ForEach(Array(topProjects.enumerated()), id: \.element.id) { index, project in
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .font(AstaSans.semiBold(9))
                            .foregroundStyle(index == 0 ? .cyan.opacity(0.85) : .white.opacity(0.3))
                            .frame(width: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name)
                                .font(AstaSans.semiBold(10.5))
                                .lineLimit(1)
                            Text("\(project.sessionCount) 个会话")
                                .font(AstaSans.regular(9))
                                .foregroundStyle(.white.opacity(0.32))
                        }
                        Spacer(minLength: 5)
                        Text(formatCompactTokens(project.tokens))
                            .font(AstaSans.regular(10.5))
                            .foregroundStyle(.cyan.opacity(0.75))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                    }
                }
            }
        }
        .padding(MonitorGeometry.cardPadding)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
        )
    }

    private var usagePeriodTitle: String {
        switch usagePeriod {
        case .week: return "近 7 日 Token"
        case .month: return "近 30 日 Token"
        case .quarter: return "近 90 日 Token"
        }
    }

    private var usageVisiblePointCount: Int {
        min(selectedUsage.series.count, usagePeriod.dayCount)
    }

    private var usageTrendStartLabel: String {
        switch usagePeriod {
        case .week: return rollingDateLabel(daysAgo: 6)
        case .month: return rollingDateLabel(daysAgo: 29)
        case .quarter: return rollingDateLabel(daysAgo: 89)
        }
    }

    private var usageTrendEndLabel: String {
        rollingDateLabel(daysAgo: 0)
    }

    private func rollingDateLabel(daysAgo: Int) -> String {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: today) ?? today
        return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
    }

    private func formatCompactTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private var quotaCard: some View {
        let planType = OpenAIPlanDisplayName.resolve(
            store.quotaState.primaryBucket?.planType
        )
        return VStack(alignment: .leading, spacing: 11) {
            dataCardHeader(
                symbol: "chart.pie.fill",
                title: "剩余额度",
                badge: planType
            ) { quotaFreshness }

            if store.quotaState.buckets.isEmpty {
                HStack {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(quotaErrorText ?? "正在连接 Codex App Server…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .frame(maxWidth: .infinity, minHeight: 68, alignment: .center)
            } else {
                ForEach(store.quotaState.buckets.prefix(2)) { bucket in
                    ForEach(Array(bucket.windows.enumerated()), id: \.offset) { _, window in
                        QuotaRow(bucket: bucket, window: window)
                    }
                }
            }
        }
        .padding(13)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private var quotaFreshness: some View {
        switch store.quotaState {
        case .loading:
            Text("正在同步")
        case let .loaded(_, date):
            Text("更新于 \(date.compactRelativeText)")
        case .failed:
            Text("数据可能已过期").foregroundStyle(.orange)
        }
    }

    private var quotaErrorText: String? {
        if case let .failed(message, _) = store.quotaState { return message }
        return nil
    }

    private var quotaDataIsStale: Bool {
        if case .failed = store.quotaState { return true }
        return false
    }

    private var currentTask: MonitoredTask? { store.currentTask }
    private var hasLiveActivity: Bool {
        !store.activeProjects.isEmpty
    }

    private var compactTopStatusText: String {
        if store.activeProjects.count > 1 { return "\(store.activeProjects.count) 项目" }
        if store.approvalProjectCount > 0 { return "需处理" }
        return hasLiveActivity ? "运行中" : compactStatusText
    }

    private var compactStatusRefreshToken: String {
        let task = currentTask
        return [
            task?.id ?? "idle",
            task?.phase.rawValue ?? "idle",
            String(task?.updatedAt.timeIntervalSinceReferenceDate ?? 0),
            String(store.activeProjects.count),
            String(store.approvalProjectCount)
        ].joined(separator: "|")
    }

    private func projectActionText(_ project: ActiveProjectState) -> String {
        project.latestDisplayActivity.map(activityDisplayTitle) ?? project.task.phase.title
    }
    private var compactStatusText: String {
        if let activity = store.sessionActivities.first {
            switch activity.kind {
            case .progress: return activity.title
            default: return activityDisplayTitle(activity)
            }
        }
        // The C mark already identifies Codex. Keeping the rest-state label to
        // two characters guarantees it remains meaningful in the narrowest
        // measured menu-bar wing instead of degrading to "Codex…".
        return currentTask?.phase.title ?? "待命"
    }

    private func activityDisplayTitle(_ activity: SessionActivityItem) -> String {
        guard activity.kind != .progress else { return activity.title }
        if activity.title.hasPrefix("正在") || activity.title.hasPrefix("已") {
            return activity.title
        }
        return (activity.isRunning ? "正在" : "已") + activity.title
    }
    private var idleAccent: Color { Color(red: 0.17, green: 0.72, blue: 1.00) }
    private var quotaAccent: Color { Color(red: 0.30, green: 0.86, blue: 1.00) }
    private var statusColor: Color { currentTask?.phase.color ?? idleAccent }
    private var taskSymbol: String {
        switch currentTask?.phase {
        case .waitingApproval: return "hand.raised.fill"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .usingTool: return "terminal.fill"
        case .ended: return "moon.fill"
        default: return "waveform.path.ecg"
        }
    }
}

private struct CompactProjectCell: View {
    let project: ActiveProjectState
    let actionText: String
    let height: CGFloat
    let singleLine: Bool
    let isFocused: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if singleLine {
                    HStack(spacing: 6) {
                        statusDot
                        Text(project.name)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                        Text("·")
                            .foregroundStyle(.white.opacity(0.28))
                        Text(actionText)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.62))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if project.sessionCount > 1 { sessionBadge }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            statusDot
                            Text(project.name)
                                .font(.system(size: 8.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 2)
                            if project.sessionCount > 1 { sessionBadge }
                            if project.task.phase == .waitingApproval {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 7, weight: .bold))
                                    .foregroundStyle(.orange)
                            }
                        }
                        HStack(spacing: 4) {
                            Image(systemName: detailSymbol)
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(project.task.phase.color.opacity(0.82))
                                .frame(width: 9)
                            Text(actionText)
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .background(
                project.task.phase == .waitingApproval
                    ? Color.orange.opacity(0.075)
                    : ((isFocused || isHovered) ? project.task.phase.color.opacity(isHovered ? 0.085 : 0.055) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(CompactPressButtonStyle())
        .onHover { hovered in
            if reduceMotion {
                isHovered = hovered
            } else {
                withAnimation(.islandHover) { isHovered = hovered }
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(project.task.phase.color)
            .frame(width: 6, height: 6)
            .shadow(
                color: project.task.phase.color.opacity(isFocused ? 0.7 : 0),
                radius: isFocused ? 3 : 0
            )
    }

    private var sessionBadge: some View {
        Text("×\(project.sessionCount)")
            .font(.system(size: 7, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.38))
    }

    private var detailSymbol: String {
        if let activity = project.latestDisplayActivity { return activity.kind.symbol }
        switch project.task.phase {
        case .waitingApproval: return "hand.raised.fill"
        case .usingTool: return "terminal.fill"
        case .working, .starting: return "waveform.path.ecg"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark"
        case .ended: return "moon.fill"
        }
    }
}

/// CodexIsland-style angular trail orbiting the complete compact silhouette.
/// It is instantiated only while work is live, so idle state has no timeline
/// updates. Both strokes remain inside the panel bounds to avoid clipped,
/// jagged outer pixels at the NSPanel edge.
private struct CompactOrbitGlow: View {
    let color: Color
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animated)) { context in
            let rotation = animated
                ? (context.date.timeIntervalSinceReferenceDate * 100)
                    .truncatingRemainder(dividingBy: 360)
                : 315
            let gradient = AngularGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.00),
                    .init(color: color.opacity(0.00), location: 0.54),
                    .init(color: color.opacity(0.32), location: 0.72),
                    .init(color: color.opacity(0.95), location: 0.84),
                    .init(color: .white.opacity(0.88), location: 0.92),
                    .init(color: color.opacity(0.00), location: 1.00)
                ]),
                center: .center,
                angle: .degrees(rotation)
            )

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .circular)
                    .strokeBorder(
                        gradient,
                        lineWidth: 5
                    )
                    .blur(radius: 3)
                    .opacity(0.58)

                RoundedRectangle(cornerRadius: 16, style: .circular)
                    .strokeBorder(
                        AngularGradient(
                            stops: [
                                .init(color: .clear, location: 0.00),
                                .init(color: color.opacity(0.00), location: 0.68),
                                .init(color: color.opacity(0.75), location: 0.86),
                                .init(color: .white.opacity(0.92), location: 0.93),
                                .init(color: .clear, location: 1.00)
                            ],
                            center: .center,
                            angle: .degrees(rotation)
                        ),
                        lineWidth: 1
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

/// Menu-bar-scale ChatGPT knot sourced from the official ChatGPT.app Retina
/// menu-bar template. Template rendering keeps the exact silhouette while
/// allowing phase colors, a quiet idle breath, and a brighter live pulse.
private struct GPTStatusMark: View {
    let active: Bool
    let color: Color
    let refreshToken: String
    let animated: Bool
    @State private var syncScale: CGFloat = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !animated)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let speed = active ? 2.6 : 1.75
            let wave = animated ? sin(phase * speed) * 0.5 + 0.5 : 0.35
            let brightness = active ? 0.68 + wave * 0.32 : 0.42 + wave * 0.24
            let haloOpacity = active ? 0.18 + wave * 0.28 : 0.06 + wave * 0.12

            ZStack {
                Circle()
                    .fill(color.opacity(haloOpacity))
                    .frame(width: active ? 15 : 14, height: active ? 15 : 14)
                    .blur(radius: active ? 3.2 : 2.5)

                Image(nsImage: Self.templateImage)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .foregroundStyle(color.opacity(brightness))
                    .frame(width: 12, height: 12)
                    .shadow(color: color.opacity(active ? 0.68 : 0.34), radius: active ? 3 : 2)

                if active {
                    Image(nsImage: Self.templateImage)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .foregroundStyle(color.opacity(0.22))
                        .frame(width: 12, height: 12)
                    .scaleEffect(CGFloat(1 + wave * 0.18))
                    .opacity(0.75 * (1 - wave))
                }
            }
        }
        .frame(width: 14, height: 14)
        .scaleEffect(syncScale)
        .onChange(of: refreshToken) { _ in
            guard active, animated else { return }
            withAnimation(.islandContentSwap) { syncScale = 1.18 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                withAnimation(.islandContentSwap) { syncScale = 1 }
            }
        }
        .accessibilityHidden(true)
    }

    private static let templateImage: NSImage = {
        // Exact 36×36 @2x menu-bar template bundled with ChatGPT.app.
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAACQAAAAkCAYAAADhAJiYAAAGcklEQVR42s2YbayXZR3HP9efc3g4wEEcgiKSIuQENCnEkUo5ZeUxS4eVtnzR1gpdTzO1CNfDirlc9aJMrfmi1Zo2K2wtQsk0TM6gLWxATUklFQNFoIOcwznA+fSi7023twcQa617++9/77qvh9/j9/f9XfB/9pTXM0ktQCmlDKonAvOBWUAnsBv4C7CmlLI9c1uAzW1KKf7HEucA1AnqEnW9+pK6V92v9qkvZvwW9fgj7NVSh1V7HpOFqkWlFNXZwNeBLqAfWAlsBF4BjgPmARcAB4FfAo/EeqcB+4CtwHpgdSmlX21l78E3YqEp6kr/9SxXL81Yh9oejTvVT6l7PPzznHqPellt72HN89oOI0RbYmAUcD3wLuBe4HOllGcbcztiobnAGGAb8DiwGdgOjIyl5gBXA+eqk4CfAL1q64iWip/b8j5bfVn9q3p6XSt1hHq+ert6IFb4nfrxBP6r3K/OU7+j7lN3qNdUMXXUAM77OPUmdVBdFgFa+Z+mfjZuUN2cgJ5cWz9cHTHEGV9OIqxT5xzOdTQ2eqv6LXWb2pO4aY+mXeqaCLJd/Z46q+5udZK6SH2/Or4K4ig0Sr0v62/Nnm2Hc1W7ekMEqZ5d6twsHKmuyvgKdUHNJdXvktqcgbwvbEDItfn2sHpC0zvUNFim9kage9Q/JXPelu+jY+rd6hV1U6tnqz/IN9Un1A15f1n9fuADdYb6uPqUOu81AmXgg1m4O+Y+TX1QfaUmUIfaHWC8MGOnqF9UN6r9EeJG9Uz1DPXz6gsR7KnE5cxYeJfaNZSFxqu/zaIlMf3ECLSnIdC6WPCqxEh3A2/uUMfU9h6rzle/28jGreom9YKES6nj0PnA2cA64L6g84QhkHxYkHoscAMwExgHLAf6gEuBK4EO9X7gwVLKHqBb3Qw8DFwLvDf7PQ8MpEb+u/6ptwUflsYKJS5bFQudm3mdsZrRtlu9Tj0p6P0JdW2+P5MUn1vPInWq+pmai7+R2GzVXXZvNvlIbezUHN6jnhUhO5MZAwG5aUNk6zT1rhxmYmpxFKzjXJf6fDDpw9V4q/Ffh/BWXNoC2kId9qUU9AA/K6U8HVxpVRhTSnka+CnwJNALvAm4E7gDWBilhpdSVgBLs/9i9bi6IM+lUp+stteYQD/QASxKTB2I0AUYGY33l1IGU4/2Z6wdmAg8ASwGHgUWhgl8NDFWgDXAauDNwCV1gbqBncBFwKmZ/BKwKoIuSeBenYJ74Cjkzli3L0X5CuCrGXsPMDEW/1uoyvEhfYcEeijVeQHw9pp77gYuB34TvnMXcAbwYiwj0F65DGivrbXm7p1x49643PChgWTaMGDqIYFKKbvi50FgmdpVShkopfQAD8Ts10ejDmAGcJU6rZTSV7mslNKXQF8UgrYPGBWLH4wgBxr09rXxGw1HJwX7k5KfVqc2iuZc9SvqlmTQ2qT6lKT+dYGCCgAfUDuz/pxk7OqUjhKIWRrIuW2oWnZeDUdU7w8aT6gTMvXK1K2/qzvVH6s/z5qd6mPh3KvVsbVa16M+Wqtp03PejjqTrKp1S70wcL5V/X0OOJhyML/aPGvGZLz+rEkdXJTysk4d3RBotTo5Zy7JuoeqtG92Fl3R8NfqLPXmFERTIJekYJ6ZIrkh5t4QgjYl+yxIAe5uCLQnAk2PlXenoH/gcK3OeYH89TXKOivIuyOCbQy1qLjS3epZdeJeO2xtVWgj0D/UP4favBCq87V62DQFOkF9JHB+TePbRaEM/XHjr9R31glazTorIvAqdWTG3xJrVM+2kMH2VwnTyKISWmm0GNGgn+PU96mXp3GsE7RZobPba/HUVVFU9eJYaLv6TXWOOvxIXLrqJuaof4g5bxliXnujek9O/Gyu9V83qqc3GoMvpWG4SR03VGMxpFD5fSgx06d+Oy1Macw9Sf1YyFZFR25PazSioeQ09cm4bHbNI62jNYrm94tA/BeATwIXA+vVZ4K+JwLTgXPy/iPgh7lw6D3Up5dyUD0ldWwGcCuwJYL6ulrpRlxcllh6dojWeDD/e4LqndG6PeA5Je3T8sxbWcHCMV/H1C8DYv4FaYVPBkYAW8KJ3pHi2wY8Fgq8Ky31bODdmb8CuLmUsql+iXHM1zCJp9YR5oxPLfpjsqc3VzR7A4zr03VMOGoAv5ELqyHWDqYhmBQ+MzPXMz3AJqC7lLKtIvD/lQur//XzT+4u16KSSLsQAAAAAElFTkSuQmCC"
        guard let data = Data(base64Encoded: encoded), let image = NSImage(data: data) else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }
        image.isTemplate = true
        return image
    }()
}

/// Compact quota identity that reads at menu-bar scale without adding another
/// word. The unfilled track remains quiet; the colored arc communicates the
/// same remaining percentage shown numerically beside it.
private struct QuotaMiniGauge: View {
    let remainingPercent: Int
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: CGFloat(max(0, min(100, remainingPercent))) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 1.7, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 11, height: 11)
        .accessibilityHidden(true)
    }
}

private struct CompactPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        CompactPressButtonBody(configuration: configuration)
    }
}

private struct CompactPressButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(reduceMotion ? nil : .islandPress, value: configuration.isPressed)
    }
}

private struct CompactMoreProjectsCell: View {
    let count: Int
    let height: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.48))
                VStack(alignment: .leading, spacing: 1) {
                    Text("+\(count) 个项目")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text("查看全部")
                        .font(.system(size: 7.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct CodexMark: View {
    var size: CGFloat = 18

    var body: some View {
        Group {
            if let image = Self.coverAILogo {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                        .fill(.white)
                    Text("C")
                        .font(.system(size: size * 0.58, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("CoverAI")
    }

    private static let coverAILogo: NSImage? = {
        guard let url = Bundle.main.url(
            forResource: "CoverAI-Logo",
            withExtension: "png"
        ) else { return nil }
        return NSImage(contentsOf: url)
    }()
}

private struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(configuration: configuration)
    }
}

private struct IslandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.45 : 0.72))
            .frame(width: 26, height: 26)
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(reduceMotion ? nil : .islandPress, value: configuration.isPressed)
    }
}

private struct QuotaRow: View {
    let bucket: RateLimitBucket
    let window: RateLimitWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(bucket.name)
                        if bucket.windows.count > 1 {
                            Text(window.windowLabel)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(progressColor.opacity(0.78))
                                .padding(.horizontal, 5)
                                .frame(height: 15)
                                .background(
                                    Capsule().fill(progressColor.opacity(0.10))
                                )
                            if window == bucket.limitingWindow {
                                Text("当前瓶颈")
                                    .font(.system(size: 8, weight: .semibold))
                                    .foregroundStyle(.orange.opacity(0.82))
                            }
                        }
                    }
                        .font(.system(size: 12, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(resetText(relativeTo: context.date))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                            .contentTransition(.numericText())
                    }
                }
                Spacer()
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("剩余")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09))
                    Capsule()
                        .fill(progressColor.gradient)
                        .frame(width: proxy.size.width * CGFloat(window.remainingPercent) / 100)
                }
            }
            .frame(height: 5)
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: window.remainingPercent
        )
    }

    private var progressColor: Color {
        if window.remainingPercent < 20 { return .red }
        if window.remainingPercent < 50 { return .orange }
        return .cyan
    }

    private func resetText(relativeTo now: Date) -> String {
        guard let date = window.resetsAt else { return window.windowLabel }
        let countdown = QuotaResetCountdown.text(until: date, relativeTo: now)
        return bucket.windows.count > 1
            ? countdown
            : "\(window.windowLabel) · \(countdown)"
    }
}

#if canImport(Translation)
@available(macOS 15.0, *)
private struct TiboChineseTranslationView: View {
    let postID: String
    let sourceText: String

    @State private var translatedText: String?
    @State private var isShowingTranslation = false
    @State private var isTranslating = false
    @State private var errorText: String?
    @State private var configuration: TranslationSession.Configuration?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isShowingTranslation, let translatedText {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Image(systemName: "character.book.closed.fill")
                        Text("中文翻译")
                        Spacer()
                        Text("系统翻译")
                            .foregroundStyle(.white.opacity(0.30))
                    }
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.72))

                    Text(translatedText)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(9)
                .background(
                    Color.cyan.opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.cyan.opacity(0.10), lineWidth: 0.6)
                }
            }

            if let errorText {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle")
                    Text(errorText)
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.orange.opacity(0.78))
            }

            Button(action: toggleTranslation) {
                HStack(spacing: 5) {
                    if isTranslating {
                        ProgressView().controlSize(.mini).tint(.cyan)
                    } else {
                        Image(systemName: isShowingTranslation
                              ? "chevron.up"
                              : "character.book.closed")
                    }
                    Text(translationButtonTitle)
                }
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.72))
                .frame(minHeight: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isTranslating || sourceText.isEmpty)
            .help("使用 macOS 系统翻译，不调用第三方翻译服务")
            .accessibilityLabel("翻译 Tibo 动态 \(postID)")
        }
        .translationTask(configuration) { session in
            do {
                let response = try await session.translate(sourceText)
                await MainActor.run {
                    translatedText = response.targetText
                    isShowingTranslation = true
                    isTranslating = false
                    errorText = nil
                }
            } catch {
                await MainActor.run {
                    isTranslating = false
                    errorText = "翻译暂不可用，请检查系统语言包"
                }
            }
        }
    }

    private var translationButtonTitle: String {
        if isTranslating { return "正在翻译…" }
        if translatedText != nil { return isShowingTranslation ? "收起中文" : "显示中文" }
        return "翻译成中文"
    }

    private func toggleTranslation() {
        if translatedText != nil {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                isShowingTranslation.toggle()
            }
            return
        }

        errorText = nil
        isTranslating = true
        let english = Locale.Language(identifier: "en")
        let simplifiedChinese = Locale.Language(identifier: "zh-Hans")
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: english,
                target: simplifiedChinese
            )
        } else {
            configuration?.invalidate()
        }
    }
}
#endif

private struct CostTrendChart: View {
    let values: [Double]
    let period: UsagePeriod
    @State private var hoveredIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            let points = UsageTrendGeometry.points(values: values, in: proxy.size)
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle()
                            .fill(.white.opacity(0.045))
                            .frame(height: 0.5)
                        Spacer(minLength: 0)
                    }
                }

                if values.contains(where: { $0 > 0 }) {
                    UsageTrendArea(points: points)
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.24), .cyan.opacity(0.07), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    UsageTrendLine(points: points)
                        .stroke(
                            LinearGradient(
                                colors: [.cyan.opacity(0.68), .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: .cyan.opacity(0.28), radius: 2)

                    if let endpoint = points.last {
                        Circle()
                            .fill(.cyan.opacity(0.18))
                            .frame(width: 13, height: 13)
                            .blur(radius: 1.5)
                            .position(endpoint)
                        Circle()
                            .fill(.cyan)
                            .frame(width: 5.5, height: 5.5)
                            .overlay(Circle().stroke(.white.opacity(0.42), lineWidth: 0.7))
                            .shadow(color: .cyan.opacity(0.75), radius: 3)
                            .position(endpoint)
                    }

                    if let hoveredIndex,
                       values.indices.contains(hoveredIndex),
                       points.indices.contains(hoveredIndex) {
                        let point = points[hoveredIndex]
                        Rectangle()
                            .fill(.white.opacity(0.13))
                            .frame(width: 0.7, height: max(1, proxy.size.height - 18))
                            .position(x: point.x, y: proxy.size.height / 2 + 9)

                        Circle()
                            .fill(.black)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.cyan, lineWidth: 2))
                            .shadow(color: .cyan.opacity(0.8), radius: 4)
                            .position(point)

                        Text("\(bucketLabel(for: hoveredIndex)) · \(formatDollars(values[hoveredIndex]))")
                            .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(.black.opacity(0.92), in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(.cyan.opacity(0.28), lineWidth: 0.6)
                            }
                            .fixedSize()
                            .position(
                                x: tooltipX(point.x, width: proxy.size.width),
                                y: 8
                            )
                    }
                } else {
                    Text("当前周期暂无可估算成本")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    guard !points.isEmpty else {
                        hoveredIndex = nil
                        return
                    }
                    let denominator = max(1, points.count - 1)
                    let ratio = min(1, max(0, location.x / max(1, proxy.size.width)))
                    hoveredIndex = min(points.count - 1, max(0, Int((ratio * CGFloat(denominator)).rounded())))
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
        .accessibilityLabel("美元成本趋势")
    }

    private func bucketLabel(for index: Int) -> String {
        let calendar = Calendar.current
        let now = Date()
        switch period {
        case .day:
            return String(format: "%02d:00–%02d:59", index, index)
        case .week:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            let date = calendar.date(byAdding: .day, value: index, to: start) ?? start
            return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        case .month:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            let date = calendar.date(byAdding: .day, value: index, to: start) ?? start
            return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        }
    }

    private func formatDollars(_ value: Double) -> String {
        value < 1 ? String(format: "$%.4f", value) : String(format: "$%.2f", value)
    }

    private func tooltipX(_ pointX: CGFloat, width: CGFloat) -> CGFloat {
        min(max(pointX, 76), max(76, width - 76))
    }
}

private struct UsageCountMetric: View {
    let value: Int
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(value)")
                .font(AstaSans.semiBold(15))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(AstaSans.regular(9))
                .foregroundStyle(.white.opacity(0.34))
        }
        .frame(minWidth: 34, alignment: .trailing)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: value)
    }
}

private struct TokenActivityHeatmap: View {
    private static let cellSize: CGFloat = 14
    private static let spacing: CGFloat = 4

    let activity: [DailyTokenActivity]
    let reduceMotion: Bool

    @State private var hoveredDate: Date?
    @State private var hoverWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(Self.cellSize), spacing: Self.spacing),
                        count: TokenActivityLayout.columnCount
                    ),
                    spacing: Self.spacing
                ) {
                    ForEach(Array(paddedActivity.enumerated()), id: \.offset) { _, day in
                        activityCell(day)
                    }
                }
                .padding(.top, 25)

                if let hovered = activity.first(where: { $0.date == hoveredDate }) {
                    Text("\(dateLabel(hovered.date)) · \(compactTokens(hovered.tokens))")
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MonitorTheme.primaryText)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Color.black.opacity(0.90), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(Color.cyan.opacity(0.28), lineWidth: 0.6)
                        }
                        .transition(.opacity)
                } else {
                    Text("悬停查看日期与 Token")
                        .font(.system(size: 7.2, weight: .medium))
                        .foregroundStyle(MonitorTheme.faintText)
                        .frame(height: 18)
                }
            }
            .frame(width: gridWidth)

            HStack {
                Text(activity.first.map { dateLabel($0.date) } ?? "—")
                Spacer()
                Text(activity.last.map { dateLabel($0.date) } ?? "—")
            }
            .font(.system(size: 7.2, weight: .medium, design: .rounded))
            .foregroundStyle(MonitorTheme.faintText)
            .frame(width: gridWidth)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredDate)
        .onChange(of: activity.map(\.date)) { _ in
            cancelHover()
        }
        .onDisappear(perform: cancelHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Token 活动热力图")
    }

    @ViewBuilder
    private func activityCell(_ day: DailyTokenActivity?) -> some View {
        if let day {
            let selected = hoveredDate == day.date
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(cellColor(tokens: day.tokens))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            selected ? Color.cyan.opacity(0.95) : Color.white.opacity(0.06),
                            lineWidth: selected ? 1.2 : 0.5
                        )
                }
                .frame(width: Self.cellSize, height: Self.cellSize)
                .contentShape(Rectangle())
                .onHover { hovering in
                    scheduleHover(day: day, hovering: hovering)
                }
                .accessibilityElement()
                .accessibilityLabel(dateLabel(day.date))
                .accessibilityValue(compactTokens(day.tokens))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: 0.6, dash: [2, 2])
                        )
                }
                .frame(width: Self.cellSize, height: Self.cellSize)
                .accessibilityHidden(true)
        }
    }

    private var paddedActivity: [DailyTokenActivity?] {
        guard !activity.isEmpty else { return [] }
        let padding = TokenActivityLayout.placeholderCount(for: activity.count)
        return Array(repeating: nil, count: padding) + activity.map(Optional.some)
    }

    private var maximumTokens: Int {
        max(1, activity.map(\.tokens).max() ?? 0)
    }

    private var gridWidth: CGFloat {
        CGFloat(TokenActivityLayout.columnCount) * Self.cellSize
            + CGFloat(TokenActivityLayout.columnCount - 1) * Self.spacing
    }

    private func cellColor(tokens: Int) -> Color {
        let level = ActivityHeatmapScale.level(
            value: Double(tokens),
            maximum: Double(maximumTokens)
        )
        return Color.white.opacity(ActivityHeatmapPalette.opacity(for: level))
    }

    private func scheduleHover(day: DailyTokenActivity, hovering: Bool) {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        guard hovering else {
            if hoveredDate == day.date { hoveredDate = nil }
            return
        }
        let work = DispatchWorkItem { hoveredDate = day.date }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cancelHover() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        hoveredDate = nil
    }

    private func dateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
    }

    private func compactTokens(_ value: Int) -> String {
        if value == 0 { return "0 tokens" }
        if value < 1_000 { return "<1K tokens" }
        if value >= 1_000_000_000 { return String(format: "%.1fB tokens", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM tokens", Double(value) / 1_000_000) }
        return String(format: "%.1fK tokens", Double(value) / 1_000)
    }
}

private struct CostActivityHeatmap: View {
    private static let cellSize: CGFloat = 14
    private static let spacing: CGFloat = 4

    let activity: [DailyCostActivity]
    let reduceMotion: Bool

    @State private var hoveredDate: Date?
    @State private var hoverWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(Self.cellSize), spacing: Self.spacing),
                        count: TokenActivityLayout.columnCount
                    ),
                    spacing: Self.spacing
                ) {
                    ForEach(Array(paddedActivity.enumerated()), id: \.offset) { _, day in
                        activityCell(day)
                    }
                }
                .padding(.top, 25)

                if let hovered = activity.first(where: { $0.date == hoveredDate }) {
                    Text("\(dateLabel(hovered.date)) · \(compactDollars(hovered.dollars))")
                        .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(MonitorTheme.primaryText)
                        .padding(.horizontal, 7)
                        .frame(height: 18)
                        .background(Color.black.opacity(0.90), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(Color.cyan.opacity(0.34), lineWidth: 0.6)
                        }
                        .transition(.opacity)
                } else {
                    Text("悬停查看日期与成本")
                        .font(.system(size: 7.2, weight: .medium))
                        .foregroundStyle(MonitorTheme.faintText)
                        .frame(height: 18)
                }
            }
            .frame(width: gridWidth)

            HStack {
                Text(activity.first.map { dateLabel($0.date) } ?? "—")
                Spacer()
                Text(activity.last.map { dateLabel($0.date) } ?? "—")
            }
            .font(.system(size: 7.2, weight: .medium, design: .rounded))
            .foregroundStyle(MonitorTheme.faintText)
            .frame(width: gridWidth)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredDate)
        .onChange(of: activity.map(\.date)) { _ in
            cancelHover()
        }
        .onDisappear(perform: cancelHover)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("成本活动热力图")
    }

    @ViewBuilder
    private func activityCell(_ day: DailyCostActivity?) -> some View {
        if let day {
            let selected = hoveredDate == day.date
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(cellColor(dollars: day.dollars))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            selected ? Color.cyan.opacity(0.95) : Color.white.opacity(0.06),
                            lineWidth: selected ? 1.2 : 0.5
                        )
                }
                .frame(width: Self.cellSize, height: Self.cellSize)
                .contentShape(Rectangle())
                .onHover { hovering in
                    scheduleHover(day: day, hovering: hovering)
                }
                .accessibilityElement()
                .accessibilityLabel(dateLabel(day.date))
                .accessibilityValue(compactDollars(day.dollars))
        } else {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.white.opacity(0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: 0.6, dash: [2, 2])
                        )
                }
                .frame(width: Self.cellSize, height: Self.cellSize)
                .accessibilityHidden(true)
        }
    }

    private var paddedActivity: [DailyCostActivity?] {
        guard !activity.isEmpty else { return [] }
        let padding = TokenActivityLayout.placeholderCount(for: activity.count)
        return Array(repeating: nil, count: padding) + activity.map(Optional.some)
    }

    private var maximumDollars: Double {
        max(0.000_001, activity.map(\.dollars).max() ?? 0)
    }

    private var gridWidth: CGFloat {
        CGFloat(TokenActivityLayout.columnCount) * Self.cellSize
            + CGFloat(TokenActivityLayout.columnCount - 1) * Self.spacing
    }

    private func cellColor(dollars: Double) -> Color {
        let level = ActivityHeatmapScale.level(value: dollars, maximum: maximumDollars)
        return Color.white.opacity(ActivityHeatmapPalette.opacity(for: level))
    }

    private func scheduleHover(day: DailyCostActivity, hovering: Bool) {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        guard hovering else {
            if hoveredDate == day.date { hoveredDate = nil }
            return
        }
        let work = DispatchWorkItem { hoveredDate = day.date }
        hoverWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func cancelHover() {
        hoverWorkItem?.cancel()
        hoverWorkItem = nil
        hoveredDate = nil
    }

    private func dateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        return "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
    }

    private func compactDollars(_ value: Double) -> String {
        if value == 0 { return "US$0" }
        if value < 1 { return String(format: "US$%.4f", value) }
        return String(format: "US$%.2f", value)
    }
}

private struct UsageTrendChart: View {
    let values: [Double]
    let period: UsageTrendPeriod
    @State private var hoveredIndex: Int?

    var body: some View {
        GeometryReader { proxy in
            let points = UsageTrendGeometry.points(values: values, in: proxy.size)
            ZStack {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Rectangle()
                            .fill(.white.opacity(0.045))
                            .frame(height: 0.5)
                        Spacer(minLength: 0)
                    }
                }

                if values.contains(where: { $0 > 0 }) {
                    UsageTrendArea(points: points)
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.24), .cyan.opacity(0.07), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    UsageTrendLine(points: points)
                        .stroke(
                            LinearGradient(
                                colors: [.cyan.opacity(0.68), .cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: .cyan.opacity(0.28), radius: 2)

                    if let endpoint = points.last {
                        Circle()
                            .fill(.cyan.opacity(0.18))
                            .frame(width: 13, height: 13)
                            .blur(radius: 1.5)
                            .position(endpoint)
                        Circle()
                            .fill(.cyan)
                            .frame(width: 5.5, height: 5.5)
                            .overlay(Circle().stroke(.white.opacity(0.42), lineWidth: 0.7))
                            .shadow(color: .cyan.opacity(0.75), radius: 3)
                            .position(endpoint)
                    }

                    if let hoveredIndex,
                       values.indices.contains(hoveredIndex),
                       points.indices.contains(hoveredIndex) {
                        let point = points[hoveredIndex]
                        Rectangle()
                            .fill(.white.opacity(0.13))
                            .frame(width: 0.7, height: max(1, proxy.size.height - 18))
                            .position(x: point.x, y: proxy.size.height / 2 + 9)

                        Circle()
                            .fill(.black)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.cyan, lineWidth: 2))
                            .shadow(color: .cyan.opacity(0.8), radius: 4)
                            .position(point)

                        Text("\(bucketLabel(for: hoveredIndex)) · \(compactTokens(values[hoveredIndex])) tokens")
                            .font(.system(size: 7.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .frame(height: 16)
                            .background(.black.opacity(0.92), in: Capsule(style: .continuous))
                            .overlay {
                                Capsule(style: .continuous)
                                    .strokeBorder(.cyan.opacity(0.28), lineWidth: 0.6)
                            }
                            .fixedSize()
                            .position(
                                x: tooltipX(point.x, width: proxy.size.width),
                                y: 8
                            )
                    }
                } else {
                    Text("当前周期暂无 Token 记录")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.3))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case let .active(location):
                    guard !points.isEmpty else {
                        hoveredIndex = nil
                        return
                    }
                    let denominator = max(1, points.count - 1)
                    let ratio = min(1, max(0, location.x / max(1, proxy.size.width)))
                    hoveredIndex = min(points.count - 1, max(0, Int((ratio * CGFloat(denominator)).rounded())))
                case .ended:
                    hoveredIndex = nil
                }
            }
        }
        .accessibilityLabel("Token 使用趋势")
    }

    private func bucketLabel(for index: Int) -> String {
        let calendar = Calendar.current
        let now = Date()
        switch period {
        case .week:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
            let date = calendar.date(byAdding: .day, value: index, to: start) ?? start
            return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        case .month:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            let date = calendar.date(byAdding: .day, value: index, to: start) ?? start
            return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        case .quarter:
            let today = calendar.startOfDay(for: now)
            let start = calendar.date(byAdding: .day, value: -89, to: today) ?? today
            let date = calendar.date(byAdding: .day, value: index, to: start) ?? start
            return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
        }
    }

    private func compactTokens(_ value: Double) -> String {
        if value >= 1_000_000_000 { return String(format: "%.2fB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.0f", value)
    }

    private func tooltipX(_ pointX: CGFloat, width: CGFloat) -> CGFloat {
        // The capsule is at most about 120pt wide at menu scale. Keep its
        // center away from either card edge without affecting point selection.
        min(max(pointX, 62), max(62, width - 62))
    }
}

private enum UsageTrendGeometry {
    static func points(values: [Double], in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        // Reserve the first 17pt for the hover value capsule.
        let top: CGFloat = 19
        let bottom = max(top, size.height - 3)
        let maximum = max(1, values.max() ?? 0)
        let denominator = max(1, values.count - 1)
        return values.indices.map { index in
            let x = size.width * CGFloat(index) / CGFloat(denominator)
            let ratio = CGFloat(max(0, values[index]) / maximum)
            return CGPoint(x: x, y: bottom - (bottom - top) * ratio)
        }
    }
}

private struct UsageTrendLine: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        return path
    }
}

private struct UsageTrendArea: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: first.x, y: rect.maxY))
        path.addLine(to: first)
        for point in points.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
