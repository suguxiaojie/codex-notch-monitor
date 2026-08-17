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

private enum ExpandedPage: String, CaseIterable, Identifiable {
    case usage = "Usage"
    case cost = "Cost"
    case tibo = "动态"
    case continuity = "会话"
    var id: String { rawValue }
}

extension Notification.Name {
    static let codexMonitorAdvancePage = Notification.Name("CodexMonitor.advancePage")
    static let codexMonitorRewindPage = Notification.Name("CodexMonitor.rewindPage")
}

struct NotchView: View {
    @ObservedObject var store: MonitorStore
    let onToggle: () -> Void
    @State private var expandedPage: ExpandedPage = .usage
    @State private var usagePeriod: UsagePeriod = .day
    @State private var costPeriod: UsagePeriod = .day
    @State private var usageAccountScopeID = UsageAccountScope.all
    @State private var compactHideWorkItem: DispatchWorkItem?
    @State private var compactHovered = false
    @State private var confirmsContinuityRecovery = false
    @State private var confirmsContinuityRollback = false
    @State private var confirmsSessionImport = false
    @State private var confirmsSessionImportRollback = false
    @State private var expandedContinuityProjectID: String?

    var body: some View {
        ZStack(alignment: .top) {
            compactView
                .opacity(store.isExpanded ? 0 : 1)

            // Keep the dashboard mounted even while compact. Its expensive
            // card hierarchy is therefore not first-built on the click frame.
            expandedView
                .padding(.top, store.compactMenuBarHeight)
                .opacity(store.isExpanded ? 1 : 0)
        }
        .frame(
            width: IslandPanelLayout.expandedWidth,
            height: IslandPanelLayout.expandedContentHeight + store.compactMenuBarHeight,
            alignment: .top
        )
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(
                cornerRadius: store.isExpanded ? 26 : 16,
                style: .continuous
            )
            .fill(Color.black.opacity(store.isExpanded ? 0.97 : 1))
            .shadow(
                color: store.isExpanded ? statusColor.opacity(0.22) : .clear,
                radius: store.isExpanded ? 18 : 0,
                y: store.isExpanded ? 8 : 0
            )
            .frame(width: store.visibleIslandWidth, height: store.visibleIslandHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .mask(alignment: .top) {
            RoundedRectangle(
                cornerRadius: store.isExpanded ? 26 : 16,
                style: .continuous
            )
            .frame(width: store.visibleIslandWidth, height: store.visibleIslandHeight)
        }
        .animation(store.isExpanded ? .islandOpen : .islandClose, value: store.isExpanded)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                CompactOrbitGlow(color: statusColor)
                    .allowsHitTesting(false)
            }
        }
        .opacity(store.compactContentVisible ? 1 : 0)
        .blur(radius: store.compactContentVisible ? 0 : 1)
        .allowsHitTesting(store.compactContentVisible && !store.isExpansionTransitioning)
        .animation(.easeOut(duration: 0.08), value: store.compactContentVisible)
        .onHover(perform: handleCompactHover)
        .onDisappear {
            compactHideWorkItem?.cancel()
            compactHideWorkItem = nil
        }
    }

    private func handleCompactHover(_ hovering: Bool) {
        withAnimation(.islandHover) { compactHovered = hovering }
        compactHideWorkItem?.cancel()
        compactHideWorkItem = nil

        if hovering {
            guard !store.compactDetailsVisible else { return }
            withAnimation(.islandOpen) { store.compactDetailsVisible = true }
            return
        }

        // Keep the project board stable while the pointer crosses its edge or
        // moves toward a project button. Approval details remain forced open.
        let workItem = DispatchWorkItem {
            guard store.approvalProjectCount == 0 else { return }
            withAnimation(.islandClose) { store.compactDetailsVisible = false }
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
                refreshToken: compactStatusRefreshToken
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
            if let window = store.quotaState.primaryBucket?.headlineWindow {
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

    private var expandedView: some View {
        VStack(spacing: 0) {
            HStack {
                CodexMark(size: 23)
                VStack(alignment: .leading, spacing: 2) {
                    Text("CODEX MONITOR")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.2)
                    Button {
                        CoverAILinks.open(.brandAttribution)
                    } label: {
                        HStack(spacing: 3) {
                            Text("BY COVERAI")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 6.5, weight: .bold))
                        }
                        .font(.system(size: 8, weight: .semibold, design: .rounded))
                        .tracking(0.35)
                        .foregroundStyle(.cyan.opacity(0.62))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("访问 CoverAI 官网")
                    .accessibilityLabel("访问 CoverAI 官网")
                }
                Spacer()
                Button {
                    store.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IslandButtonStyle())
                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                }
                .buttonStyle(IslandButtonStyle())
            }
            .padding(.horizontal, 20)
            .padding(.top, 17)
            .padding(.bottom, 14)

            Divider().overlay(.white.opacity(0.09))

            pageSwitcher
                .padding(.horizontal, 15)
                .padding(.top, 11)

            Group {
                if expandedPage == .usage {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 10) {
                            usageOverviewCard
                            usageProjectCard
                            taskCard
                            activityCard
                            quotaCard
                            coverAIPromoCard
                        }
                    }
                    .transition(pageTransition)
                } else if expandedPage == .cost {
                    costPage
                        .transition(pageTransition)
                } else if expandedPage == .tibo {
                    tiboPage
                        .transition(pageTransition)
                } else {
                    continuityPage
                        .transition(pageTransition)
                }
            }
            .padding(.horizontal, 15)
            .padding(.top, 10)

            Text(expandedFooterText)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.32))
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
                .padding(.bottom, 12)
        }
        .frame(
            width: IslandPanelLayout.expandedWidth,
            height: IslandPanelLayout.expandedContentHeight
        )
        // The host window begins growing before the dense panel content is
        // revealed. This avoids rendering the full dashboard through a
        // menu-bar-sized clipping rectangle during the first animation frames.
        .opacity(store.expandedContentVisible ? 1 : 0)
        .offset(y: store.expandedContentVisible ? 0 : -8)
        .blur(radius: store.expandedContentVisible ? 0 : 1.5)
        .allowsHitTesting(store.expandedContentVisible && !store.isExpansionTransitioning)
        .animation(.islandContentSwap, value: store.expandedContentVisible)
        .onReceive(NotificationCenter.default.publisher(for: .codexMonitorAdvancePage)) { _ in
            movePage(by: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .codexMonitorRewindPage)) { _ in
            movePage(by: -1)
        }
    }

    private func showPage(_ page: ExpandedPage) {
        guard store.isExpanded, store.expandedContentVisible, expandedPage != page else { return }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
            expandedPage = page
        }
    }

    private func movePage(by offset: Int) {
        let pages = ExpandedPage.allCases
        guard let current = pages.firstIndex(of: expandedPage) else { return }
        let target = max(0, min(pages.count - 1, current + offset))
        showPage(pages[target])
    }

    private var expandedFooterText: String {
        switch expandedPage {
        case .usage: return "触控板双指左右滑动 · 数据仅在本机处理"
        case .cost: return "API 等价成本估算 · 不代表订阅实际扣款"
        case .tibo: return "非官方动态 · 以原始 X 内容为准"
        case .continuity: return "本地会话管理 · 不读取或保存账号凭据"
        }
    }

    private var pageSwitcher: some View {
        HStack(spacing: 3) {
            ForEach(ExpandedPage.allCases) { page in
                Button {
                    showPage(page)
                } label: {
                    ZStack {
                        if expandedPage == page {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.white.opacity(0.11))
                        }
                        HStack(spacing: 4) {
                            Text(page.rawValue)
                            if page == .continuity,
                               (!store.continuitySnapshot.recoverableThreads.isEmpty || store.continuityError != nil) {
                                Circle()
                                    .fill(store.continuityError == nil ? Color.cyan : Color.orange)
                                    .frame(width: 4, height: 4)
                            }
                        }
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(expandedPage == page ? .white : .white.opacity(0.42))
                    }
                    .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                    // An explicit rectangular hit shape makes the complete
                    // segment clickable, including transparent padding.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                .contentShape(Rectangle())
            }
        }
        .padding(3)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var pageTransition: AnyTransition {
        .opacity.combined(with: .offset(x: expandedPage == .usage ? -14 : 14))
    }

    private var continuityPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                continuityAccountCard
                continuitySummaryCard
                if let preview = store.sessionImportPreview {
                    sessionImportPreviewCard(preview)
                }
                if let message = store.continuityStatusMessage {
                    continuityMessageCard(message, color: .cyan)
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
        .alert("导入会话备份", isPresented: $confirmsSessionImport) {
            Button("取消", role: .cancel) { }
            Button("备份并导入") { store.importSelectedSessionBundle() }
        } message: {
            Text("请先使用 Cmd + Q 完全退出 Codex／ChatGPT Desktop。插件会先备份本地索引和项目状态；默认跳过同 ID 会话，不会覆盖现有对话。")
        }
        .alert("撤销上次导入", isPresented: $confirmsSessionImportRollback) {
            Button("取消", role: .cancel) { }
            Button("确认撤销") { store.rollbackLastSessionImport() }
        } message: {
            Text("请先完全退出 Codex／ChatGPT Desktop。本次新建的会话将被移除，导入前的索引和项目状态将从校验备份恢复。")
        }
    }

    private var continuityAccountCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.cyan.opacity(0.12)).frame(width: 42, height: 42)
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(store.continuityAccountTitle)
                    .font(.system(size: 12, weight: .bold))
                if let subtitle = store.continuityAccountSubtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 8.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.42))
                }
            }
            Spacer()
            if store.isContinuityLoading {
                ProgressView().controlSize(.small).tint(.cyan)
            } else {
                Button { store.refreshContinuity(forceInventory: true) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 28)
                        .background(.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
                .help("重新检查账号与本地会话")
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var continuitySummaryCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("本地连续性")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Text(continuitySummaryStatus)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(continuitySummaryStatusColor)
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
                    HStack {
                        Image(systemName: "externaldrive.badge.plus")
                        Text("备份并恢复待处理会话")
                        Spacer()
                        if store.isContinuityRecovering { ProgressView().controlSize(.mini).tint(.cyan) }
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 11)
                    .frame(height: 31)
                    .background(Color.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(store.isContinuityRecovering)
            }
            Button {
                store.chooseSessionImportBundle()
            } label: {
                HStack {
                    Image(systemName: "square.and.arrow.down")
                    Text("导入 .codexmonitorbundle")
                    Spacer()
                    if store.isSessionImporting { ProgressView().controlSize(.mini).tint(.cyan) }
                }
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.cyan)
                .padding(.horizontal, 11)
                .frame(height: 31)
                .background(Color.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(store.isSessionImporting)
            .help("选择并校验 Codex Notch Monitor 会话备份")
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var continuitySummaryStatus: String {
        if let progress = store.continuityScanProgress, progress.total > 0 {
            return "正在扫描 \(progress.completed)/\(progress.total)"
        }
        if store.isContinuityLoading { return "正在确认" }
        return store.continuitySnapshot.recoverableThreads.isEmpty ? "记录完整" : "需要处理"
    }

    private func sessionImportPreviewCard(_ preview: SessionImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .foregroundStyle(.green)
                Text("备份校验通过")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                Text(SessionPortableManifest.supportedFormat)
                    .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.32))
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(preview.manifest.project.displayName)
                    .font(.system(size: 10, weight: .semibold))
                Text(preview.bundleURL.lastPathComponent)
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.36))
                    .lineLimit(1)
            }

            HStack(spacing: 0) {
                continuityMetric(preview.sessionCount, "总会话")
                continuityMetric(preview.activeCount, "活动")
                continuityMetric(preview.archivedCount, "已归档")
                continuityMetric(preview.duplicateCount, "重复")
            }

            if preview.requiresPathMapping {
                Button {
                    store.chooseSessionImportProjectDirectory()
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "folder.badge.questionmark")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.sessionImportMappedProjectURL == nil ? "原路径不存在，选择新项目目录" : "已映射到新项目")
                            Text(store.sessionImportMappedProjectURL?.path ?? preview.manifest.project.originalPath)
                                .font(.system(size: 7.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.35))
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(store.sessionImportMappedProjectURL == nil ? .orange : .cyan)
                    .padding(.horizontal, 10)
                    .frame(height: 39)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                HStack(spacing: 7) {
                    Image(systemName: "folder.fill").foregroundStyle(.cyan)
                    Text(preview.manifest.project.originalPath)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                }
            }

            if preview.duplicateCount > 0 {
                VStack(alignment: .leading, spacing: 5) {
                    Text("同 ID 会话处理")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                    HStack(spacing: 5) {
                        ForEach(SessionImportDuplicateStrategy.allCases, id: \.rawValue) { strategy in
                            Button {
                                store.sessionImportDuplicateStrategy = strategy
                            } label: {
                                Text(strategy == .skip ? "跳过重复" : "作为副本")
                                    .font(.system(size: 8.5, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 27)
                                    .background(
                                        store.sessionImportDuplicateStrategy == strategy
                                            ? Color.cyan.opacity(0.16)
                                            : Color.white.opacity(0.04),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(store.sessionImportDuplicateStrategy == strategy ? .cyan : .white.opacity(0.5))
                        }
                    }
                }
            }

            HStack(spacing: 7) {
                Button("取消") { store.cancelSessionImport() }
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .buttonStyle(.plain)
                Button("备份并导入") { confirmsSessionImport = true }
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .background(Color.cyan.opacity(0.13), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan)
                    .disabled(preview.requiresPathMapping && store.sessionImportMappedProjectURL == nil)
            }
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var continuitySummaryStatusColor: Color {
        if store.isContinuityLoading { return .cyan }
        return store.continuitySnapshot.recoverableThreads.isEmpty ? .green : .orange
    }

    private func continuityMetric(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
        }
        .frame(maxWidth: .infinity)
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

    private var continuityThreadCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("最近项目会话")
                    .font(.system(size: 11, weight: .bold))
                Spacer()
                if store.continuitySnapshot.baselineOwnershipCount > 0 {
                    Text("\(store.continuitySnapshot.baselineOwnershipCount) 条基线前会话")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                        .help("插件建立账号基线前已存在，无法可靠反推创建账号")
                } else if store.continuitySnapshot.unknownOwnershipCount > 0 {
                    Text("\(store.continuitySnapshot.unknownOwnershipCount) 条尚未建立归属")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            if store.continuitySnapshot.userThreads.isEmpty {
                Text("暂未发现本地 Codex 会话")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 54)
            } else {
                ForEach(store.continuitySnapshot.projectGroups) { project in
                    continuityProjectSection(project)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onAppear {
            if expandedContinuityProjectID == nil {
                expandedContinuityProjectID = store.continuitySnapshot.projectGroups.first?.id
            }
        }
        .onChange(of: store.continuitySnapshot.projectGroups.map(\.id)) { projectIDs in
            if let expandedContinuityProjectID,
               projectIDs.contains(expandedContinuityProjectID) {
                return
            }
            expandedContinuityProjectID = projectIDs.first
        }
    }

    private func continuityProjectSection(_ project: ContinuityProjectGroup) -> some View {
        let isExpanded = expandedContinuityProjectID == project.id
        return VStack(spacing: 7) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.islandContentSwap) {
                        expandedContinuityProjectID = isExpanded ? nil : project.id
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.cyan)
                            .frame(width: 18, height: 18)
                            .background(Color.cyan.opacity(0.09), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text(project.name)
                            .font(.system(size: 10, weight: .bold))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(project.threads.count) 个对话")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.34))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.32))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                    .frame(maxWidth: .infinity, minHeight: 29)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    store.exportProject(project)
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .frame(width: 27, height: 27)
                        .background(Color.cyan.opacity(0.08), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("导出此项目的 \(project.threads.count) 条会话")
            }

            if isExpanded {
                HStack(alignment: .top, spacing: 9) {
                    Capsule()
                        .fill(Color.cyan.opacity(0.16))
                        .frame(width: 1.5)
                    VStack(spacing: 7) {
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
        .padding(.vertical, 7)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func continuityThreadRow(_ thread: LocalThreadRecord) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(thread.visibility == .visible ? Color.green : (thread.visibility == .localOnly ? .orange : .red))
                .frame(width: 5, height: 5)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(thread.visibility.title)
                    if thread.isArchived { Text("· 已归档") }
                    Text("·")
                    Text(ownershipTitle(thread.ownership))
                }
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white.opacity(0.36))
            }
            Spacer(minLength: 6)
            if thread.canExportSummary {
                Button {
                    store.copyHandoffSummary(for: thread)
                } label: {
                    Text("复制摘要")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.cyan)
                        .padding(.horizontal, 8)
                        .frame(height: 23)
                        .background(Color.cyan.opacity(0.08), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("复制经脱敏的本地交接摘要，不会创建新会话")
            }
            Button {
                store.exportSession(thread)
            } label: {
                Text("导出")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 8)
                    .frame(height: 23)
                    .background(Color.cyan.opacity(0.08), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("导出脱敏的可读副本或原始可恢复备份")
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

    private var tiboPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                quotaResetHistoryCard
                tiboSourceCard
                if let feed = store.tiboFeed, !feed.displayEvents().isEmpty {
                    ForEach(feed.displayEvents().prefix(12)) { item in
                        tiboEventCard(item)
                    }
                } else if store.isTiboFeedLoading {
                    VStack(spacing: 9) {
                        ProgressView().controlSize(.small).tint(.cyan)
                        Text("正在获取 Tibo 的 Codex 额度动态…")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                    .frame(maxWidth: .infinity, minHeight: 130)
                    .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    Text("暂时没有可显示的额度动态")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .onAppear {
            store.refreshTiboFeed(ifOlderThan: 5 * 60)
        }
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

            if store.quotaResetEvents.isEmpty {
                Text("正在监控官方临时重置与窗口到期重置")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
            } else {
                ForEach(store.quotaResetEvents.prefix(3)) { event in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: quotaResetSymbol(event.reason))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(quotaResetColor(event.reason))
                            .frame(width: 13, height: 14)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.reason.title)
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

    private func quotaResetSymbol(_ reason: QuotaResetReason) -> String {
        switch reason {
        case .officialCompleted: return "bolt.fill"
        case .officialScheduled: return "calendar.badge.checkmark"
        case .natural: return "clock.arrow.circlepath"
        case .mixed: return "checkmark.seal.fill"
        case .unverified: return "questionmark.circle.fill"
        }
    }

    private func quotaResetColor(_ reason: QuotaResetReason) -> Color {
        switch reason {
        case .officialCompleted: return .green
        case .officialScheduled: return .cyan
        case .natural: return .blue
        case .mixed: return .mint
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
        guard let date = store.tiboFeed?.lastSuccessfulCheckDate
                ?? store.tiboFeed?.generatedDate else { return store.tiboFeedError != nil }
        return Date().timeIntervalSince(date) > TiboFeedService.staleInterval
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

    private var costPage: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                costOverviewCard
                costTrendCard
                providerCostCard
                coverAIPromoCard
            }
        }
    }

    private var costOverviewCard: some View {
        let totals = selectedCost
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 3) {
                ForEach(UsagePeriod.allCases) { period in
                    Button {
                        withAnimation(.islandContentSwap) { costPeriod = period }
                    } label: {
                        Text(period.rawValue)
                            .font(.system(size: 9, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .foregroundStyle(costPeriod == period ? .white : .white.opacity(0.4))
                            .background(
                                costPeriod == period ? Color.white.opacity(0.11) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            accountScopeControl

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(costPeriodTitle)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.46))
                    Text(formatDollars(totals.dollars))
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan.opacity(0.9))
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Token 吞吐量")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.36))
                    Text(formatTokens(totals.tokens))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }

            HStack(spacing: 8) {
                Text("输入 \(formatCompactTokens(totals.inputTokens))")
                Text("输出 \(formatCompactTokens(totals.outputTokens))")
                Text("缓存 \(formatCompactTokens(totals.cacheTokens))")
                Spacer(minLength: 0)
                if store.isCostLoading { ProgressView().controlSize(.mini).tint(.cyan) }
            }
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.38))
            .lineLimit(1)
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var coverAIPromoCard: some View {
        Button {
            CoverAILinks.open(.dashboardCard)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [.cyan.opacity(0.22), .blue.opacity(0.12)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.cyan.opacity(0.92))
                }
                .frame(width: 31, height: 31)

                VStack(alignment: .leading, spacing: 2) {
                    Text("CoverAI")
                        .font(.system(size: 10, weight: .semibold))
                    Text("发现实用的 AI 工具、订阅与使用指南")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.44))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                HStack(spacing: 4) {
                    Text("访问官网")
                    Image(systemName: "arrow.up.right")
                }
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(.cyan.opacity(0.78))
            }
            .padding(.horizontal, 11)
            .frame(maxWidth: .infinity, minHeight: 49, maxHeight: 49)
            .background(
                LinearGradient(
                    colors: [.white.opacity(0.065), .cyan.opacity(0.035)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.cyan.opacity(0.10), lineWidth: 0.6)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CompactPressButtonStyle())
        .help("在默认浏览器打开 coverai.store")
        .accessibilityLabel("访问 CoverAI 官网")
    }

    private var costTrendCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("美元成本趋势")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(costTrendContext)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.34))
            }
            CostTrendChart(
                values: Array(selectedCost.series.prefix(costVisiblePointCount)),
                period: costPeriod
            )
            .frame(height: 58)

            HStack {
                Text(costTrendStartLabel)
                Spacer()
                Text(costTrendEndLabel)
            }
            .font(.system(size: 7.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.28))
        }
        .padding(11)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var providerCostCard: some View {
        VStack(spacing: 7) {
            HStack {
                Text("本地日志来源")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if store.isCostLoading { ProgressView().controlSize(.mini).tint(.cyan) }
                Button { store.refreshCost() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
            }
            ForEach(selectedCostScope.providers) { provider in
                let totals = provider.totals(for: costPeriod)
                VStack(spacing: 4) {
                    HStack {
                        Circle()
                            .fill(Color.cyan)
                            .frame(width: 6, height: 6)
                        Text(provider.provider.rawValue)
                            .font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text(costPeriod.rawValue + "统计")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.34))
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
                            Spacer()
                            Text("等价成本")
                                .foregroundStyle(.white.opacity(0.42))
                            Text(formatDollars(totals.dollars))
                                .fontWeight(.bold)
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 9, weight: .medium, design: .rounded))
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
        .padding(11)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var accountScopeControl: some View {
        VStack(spacing: 3) {
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
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.cyan.opacity(0.72))
                    Text("账号")
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                    Spacer(minLength: 6)
                    Text(selectedAccountScopeTitle)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 6.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.32))
                }
                .padding(.horizontal, 9)
                .frame(maxWidth: .infinity, minHeight: 24)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)

            Text(accountScopeEvidenceText)
                .font(.system(size: 7.2, weight: .medium))
                .foregroundStyle(.white.opacity(0.28))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
        }
    }

    private func accountScopeButton(id: String, title: String) -> some View {
        Button {
            withAnimation(.islandContentSwap) { usageAccountScopeID = id }
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
        return "仅显示插件可靠观察到归属该账号的会话"
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

    private var costPeriodTitle: String {
        switch costPeriod {
        case .day: return "今日 API 等价成本"
        case .week: return "近 7 日 API 等价成本"
        case .month: return "近 30 日 API 等价成本"
        }
    }

    private var costTrendContext: String {
        switch costPeriod {
        case .day: return "今日 · 每小时成本"
        case .week: return "近 7 日 · 每日成本"
        case .month: return "近 30 日 · 每日成本"
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

    private var usageOverviewCard: some View {
        let usage = selectedUsage
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 3) {
                ForEach(UsagePeriod.allCases) { period in
                    Button {
                        withAnimation(.islandContentSwap) { usagePeriod = period }
                    } label: {
                        Text(period.rawValue)
                            .font(.system(size: 9, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 22)
                            .foregroundStyle(usagePeriod == period ? .white : .white.opacity(0.4))
                            .background(
                                usagePeriod == period ? Color.white.opacity(0.11) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            accountScopeControl

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(usagePeriodTitle)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.46))
                    Text(formatTokens(usage.tokens))
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(.cyan.opacity(0.9))
                        .monospacedDigit()
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
            .font(.system(size: 8, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.38))
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
            .font(.system(size: 7.5, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.28))
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var usageProjectCard: some View {
        let usage = selectedUsage
        let topProjects = Array(usage.projects.prefix(4))
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("项目用量排行")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(usagePeriod.rawValue + "统计")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.32))
            }
            if topProjects.isEmpty {
                Text("当前周期暂无本地 Token 记录")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            } else {
                ForEach(Array(topProjects.enumerated()), id: \.element.id) { index, project in
                    HStack(spacing: 7) {
                        Text("\(index + 1)")
                            .font(.system(size: 8, weight: .bold, design: .rounded))
                            .foregroundStyle(index == 0 ? .cyan.opacity(0.85) : .white.opacity(0.3))
                            .frame(width: 10)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(project.name)
                                .font(.system(size: 9.5, weight: .semibold))
                                .lineLimit(1)
                            Text("\(project.sessionCount) 个会话")
                                .font(.system(size: 7.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.32))
                        }
                        Spacer(minLength: 5)
                        Text(formatCompactTokens(project.tokens))
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan.opacity(0.75))
                            .monospacedDigit()
                    }
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var usagePeriodTitle: String {
        switch usagePeriod {
        case .day: return "今日 Token"
        case .week: return "近 7 日 Token"
        case .month: return "近 30 日 Token"
        }
    }

    private var usageVisiblePointCount: Int {
        let calendar = Calendar.current
        switch usagePeriod {
        case .day:
            return min(selectedUsage.series.count, calendar.component(.hour, from: Date()) + 1)
        case .week:
            return min(selectedUsage.series.count, 7)
        case .month:
            return min(selectedUsage.series.count, 30)
        }
    }

    private var usageTrendStartLabel: String {
        switch usagePeriod {
        case .day: return "00 时"
        case .week: return rollingDateLabel(daysAgo: 6)
        case .month: return rollingDateLabel(daysAgo: 29)
        }
    }

    private var usageTrendEndLabel: String {
        switch usagePeriod {
        case .day: return "23 时"
        case .week, .month: return rollingDateLabel(daysAgo: 0)
        }
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

    private var taskCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("活跃项目")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text("\(store.activeProjects.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan.opacity(0.8))
            }

            if store.activeProjects.isEmpty {
                Text("当前没有运行中的项目")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            } else {
                ForEach(store.activeProjects) { project in
                    Button { store.selectProject(project.id) } label: {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(project.task.phase.color)
                                .frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(project.name)
                                    .font(.system(size: 10, weight: .semibold))
                                    .lineLimit(1)
                                Text("\(project.sessionCount) 个运行会话")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.42))
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 6)
                            Text(project.task.phase.title)
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(project.task.phase.color.opacity(0.85))
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 34)
                        .background(
                            store.selectedProject?.id == project.id
                                ? Color.white.opacity(0.075) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var quotaCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("剩余额度")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                if let planType = store.quotaState.primaryBucket?.planType,
                   !planType.isEmpty {
                    Text(planType.uppercased())
                        .font(.system(size: 7, weight: .bold, design: .rounded))
                        .tracking(0.35)
                        .foregroundStyle(.cyan.opacity(0.72))
                        .padding(.horizontal, 6)
                        .frame(height: 15)
                        .background(.cyan.opacity(0.09), in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(.cyan.opacity(0.15), lineWidth: 0.5)
                        }
                }
                Spacer()
                quotaFreshness
            }

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

    private var activityCard: some View {
        let project = store.selectedProject
        let activities = project?.activities ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(project == nil ? "实时运行内容" : "实时动作")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                if !activities.isEmpty {
                    Text("最近 \(min(activities.count, 3)) 条")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.34))
                }
                if project?.latestDisplayActivity?.isRunning == true {
                    ProgressView().controlSize(.mini).tint(.cyan)
                }
            }

            if activities.isEmpty {
                Text(currentTask == nil ? "当前没有运行中的任务" : currentTask?.phase.title ?? "正在同步活动")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            } else {
                ForEach(activities.prefix(3)) { activity in
                    HStack(spacing: 8) {
                        Image(systemName: activity.kind.symbol)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(activity.isRunning ? .cyan : .white.opacity(0.4))
                            .frame(width: 13)
                        Text(activityDisplayTitle(activity))
                            .font(.system(size: 10, weight: activity.isRunning ? .semibold : .regular))
                            .foregroundStyle(.white.opacity(activity.isRunning ? 0.86 : 0.48))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                    }
                }
            }
        }
        .padding(12)
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
            withAnimation(.islandHover) { isHovered = hovered }
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

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let rotation = (context.date.timeIntervalSinceReferenceDate * 100)
                .truncatingRemainder(dividingBy: 360)
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
    @State private var syncScale: CGFloat = 1

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
            let speed = active ? 2.6 : 1.75
            let wave = sin(phase * speed) * 0.5 + 0.5
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
            guard active else { return }
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
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.84 : 1)
            .animation(.islandPress, value: configuration.isPressed)
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

private struct CodexMark: View {
    var size: CGFloat = 18
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(.white)
            Text("C")
                .font(.system(size: size * 0.58, weight: .black, design: .rounded))
                .foregroundStyle(.black)
        }
        .frame(width: size, height: size)
    }
}

private struct IslandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.45 : 0.72))
            .frame(width: 26, height: 26)
            .background(.white.opacity(configuration.isPressed ? 0.12 : 0.07), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.islandPress, value: configuration.isPressed)
    }
}

private struct QuotaRow: View {
    let bucket: RateLimitBucket
    let window: RateLimitWindow

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
                        }
                    }
                        .font(.system(size: 12, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(resetText(relativeTo: context.date))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.42))
                    }
                }
                Spacer()
                Text("\(window.remainingPercent)%")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .monospacedDigit()
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
            withAnimation(.easeOut(duration: 0.16)) {
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

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(value)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(label)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.34))
        }
        .frame(minWidth: 34, alignment: .trailing)
    }
}

private struct UsageTrendChart: View {
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
