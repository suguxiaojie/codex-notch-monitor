import AppKit
import SwiftUI

private enum SetupOnboardingStep: Int, CaseIterable {
    case welcome
    case environment
    case notifications
    case hooks
    case verify

    var title: String {
        switch self {
        case .welcome: return "欢迎"
        case .environment: return "环境检查"
        case .notifications: return "通知"
        case .hooks: return "Hooks"
        case .verify: return "完成"
        }
    }
}

struct SetupPermissionsView: View {
    @ObservedObject var store: MonitorStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("setup.onboarding.currentStep") private var persistedStepRawValue = 0
    @State private var step: SetupOnboardingStep = .welcome
    @State private var confirmsHookInstall = false
    @State private var confirmsHookUninstall = false
    @State private var confirmsSecurityReviewCompletion = false
    @State private var environmentDetailsExpanded = false
    @State private var updateDetailsExpanded = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 16) {
                if store.isSetupOnboardingComplete {
                    maintenanceDashboard
                } else {
                    onboardingProgress
                    onboardingCard
                }
                if shouldShowSetupMessage, let message = store.codexSetupMessage {
                    setupMessage(message)
                }
            }
            .frame(maxWidth: 840)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
        .font(MonitorDesktopTypography.body)
        .foregroundStyle(MonitorDesktopTheme.primaryText)
        .controlSize(.regular)
        .onAppear {
            step = SetupOnboardingStep(rawValue: persistedStepRawValue) ?? .welcome
            store.refreshCodexSetup()
            store.refreshNotificationStatus()
            store.checkForAppUpdate(force: false)
            reconcileStepWithSetupState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshNotificationStatus()
        }
        .onChange(of: step) { value in
            persistedStepRawValue = value.rawValue
        }
        .onChange(of: store.codexSetupSnapshot?.hookState) { _ in
            reconcileStepWithSetupState()
        }
        .alert("备份并安装 Codex Hooks？", isPresented: $confirmsHookInstall) {
            Button("取消", role: .cancel) {}
            Button("备份并安装") { store.installCodexSetupHooks() }
        } message: {
            Text("将备份并合并 ~/.codex/hooks.json，保留其他已有 Hooks；Helper 会复制到应用支持目录的稳定路径。安装后请在 /hooks 确认当前 Hook 为 Active；只有出现新定义审核菜单时才需要选择“2. Trust all and continue”。")
        }
        .alert("卸载 Codex Monitor Hooks？", isPresented: $confirmsHookUninstall) {
            Button("取消", role: .cancel) {}
            Button("备份并卸载", role: .destructive) {
                store.uninstallCodexSetupHooks()
            }
        } message: {
            Text("将先备份 ~/.codex/hooks.json，再只移除命令中属于 CodexMonitorHook 的 Handler；不会删除其他 Hooks。")
        }
        .alert("确认当前 Hook 已在 Codex 激活？", isPresented: $confirmsSecurityReviewCompletion) {
            Button("取消", role: .cancel) {}
            Button("确认已 Active") {
                store.confirmCodexHookSecurityReview()
            }
        } message: {
            Text("只有你已在 /hooks 确认当前 Codex Monitor Hook 为 Active，或已经完成新定义的信任审核后才确认。此操作只记录当前安装哈希；最终仍需首条真实 Hook 事件验证。")
        }
    }

    private var onboardingProgress: some View {
        HStack(spacing: 6) {
            ForEach(SetupOnboardingStep.allCases, id: \.rawValue) { item in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(
                            item.rawValue <= step.rawValue
                                ? MonitorDesktopTheme.selection
                                : MonitorDesktopTheme.controlFill
                        )
                        .frame(height: 4)
                    Text(item.title)
                        .font(MonitorDesktopTypography.metadata)
                        .foregroundStyle(
                            item == step
                                ? MonitorDesktopTheme.primaryText
                                : MonitorDesktopTheme.faintText
                        )
                }
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("安装引导，第 \(step.rawValue + 1) 步，共 \(SetupOnboardingStep.allCases.count) 步：\(step.title)")
    }

    @ViewBuilder
    private var onboardingCard: some View {
        switch step {
        case .welcome:
            welcomeCard
        case .environment:
            environmentCard
        case .notifications:
            notificationsCard
        case .hooks:
            hooksCard
        case .verify:
            verificationCard
        }
    }

    private var welcomeCard: some View {
        setupCard {
            setupHero(
                symbol: "checkmark.shield.fill",
                color: .cyan,
                title: "设置 Codex Monitor",
                detail: "开启需要的通知与任务状态功能。你也可以稍后设置。"
            )
            setupDivider
            VStack(alignment: .leading, spacing: 9) {
                setupBullet("所有统计与事件只在本机处理", symbol: "lock.fill")
                setupBullet("Hook 不读取提示词、工具输出或完整对话", symbol: "text.badge.xmark")
                setupBullet("不需要管理员密码，也不会安装系统服务", symbol: "person.badge.shield.checkmark")
                setupBullet("通知与 Hooks 均可跳过，稍后可从本页重新设置", symbol: "arrow.uturn.backward.circle")
            }
            setupDivider
            HStack(spacing: 8) {
                Button("稍后设置") {
                    finishOnboarding()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("开始设置") { advance() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var environmentCard: some View {
        setupCard {
            setupSectionTitle("环境检查", detail: "确认本机运行环境与 Hook 配置。")
            setupDivider
            environmentStatusRows
            setupDivider
            DisclosureGroup("配置位置", isExpanded: $environmentDetailsExpanded) {
                VStack(alignment: .leading, spacing: 14) {
                    pathBlock("Hook 配置", path: snapshot?.hooksURL.path ?? "~/.codex/hooks.json")
                    pathBlock("稳定 Helper", path: snapshot?.installedHelperURL.path ?? "应用支持目录")
                }
                .padding(.top, 12)
                .modifier(MonitorDesktopReveal())
            }
            .animation(disclosureAnimation, value: environmentDetailsExpanded)
            navigationButtons(nextDisabled: snapshot == nil || snapshot?.hookState == .checking)
        }
    }

    private var notificationsCard: some View {
        setupCard {
            setupSectionTitle(
                "通知权限",
                detail: "用于额度恢复、待确认重置和需要处理的状态；不影响基础统计。"
            )
            setupDivider
            setupStatusRow(
                "系统通知",
                value: notificationStatusTitle,
                color: notificationStatusColor
            )
            Text(notificationActionDetail)
                .font(MonitorDesktopTypography.body)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            setupDivider
            HStack(spacing: 8) {
                Button("返回") { rewind() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("跳过") { advance() }
                    .buttonStyle(.bordered)
                if store.quotaNotificationStatus != .enabled {
                    notificationPermissionButton
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("下一步") { advance() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var hooksCard: some View {
        setupCard {
            setupSectionTitle(
                "Codex 生命周期 Hooks",
                detail: "用于开始、工具调用、等待批准和完成等精细阶段。基础额度与历史统计不依赖它。"
            )
            setupDivider
            setupStatusRow(
                "Hook 状态",
                value: displayedHookStateTitle,
                color: hookStateColor
            )
            VStack(alignment: .leading, spacing: 6) {
                Text("安装会做什么")
                    .font(MonitorDesktopTypography.rowTitle)
                Text("• 备份并合并 ~/.codex/hooks.json\n• 保留其他已有 Hooks\n• 安装 9 类当前用户事件，单次同步等待上限 2 秒\n• Helper 只写入一个小型本地事件，不执行网络请求")
                    .font(MonitorDesktopTypography.body)
                    .foregroundStyle(MonitorDesktopTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            setupDivider
            hooksStepActions
        }
    }

    @ViewBuilder
    private var hooksStepActions: some View {
        HStack(spacing: 8) {
            Button("返回") { rewind() }
                .buttonStyle(.bordered)
            Spacer()

            switch snapshot?.hookState.onboardingStepMode {
            case .install:
                Button("跳过 Hook") { step = .verify }
                    .buttonStyle(.bordered)
                Button(store.isCodexSetupWorking ? "正在更新" : hookInstallActionTitle) {
                    confirmsHookInstall = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isCodexSetupWorking)

            case .review:
                Button("稍后审核") {
                    finishOnboarding()
                }
                .buttonStyle(.bordered)
                if store.isCodexSecurityReviewLaunching {
                    Button("正在打开") {}
                        .buttonStyle(.borderedProminent)
                        .disabled(true)
                } else {
                    Button(snapshot?.hookState.reviewActionTitle ?? "检查 Hooks 状态") {
                        store.openCodexHookSecurityReview()
                        step = .verify
                    }
                        .buttonStyle(.borderedProminent)
                }

            case .advance:
                Button("下一步") { step = .verify }
                    .buttonStyle(.borderedProminent)

            case .deferOnly:
                Button("稍后处理") {
                    finishOnboarding()
                }
                .buttonStyle(.bordered)

            case .checking, .none:
                Button("正在检查") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
            }
        }
    }

    private var verificationCard: some View {
        setupCard {
            setupSectionTitle(
                "Hooks 状态与连接验证",
                detail: verificationDetail
            )
            setupDivider
            setupStatusRow(
                "Hook 状态",
                value: displayedHookStateTitle,
                color: hookStateColor
            )
            if snapshot?.hookState.needsTrustConfirmation == true {
                Text(
                    store.isCodexSecurityReviewLaunching
                        ? "正在打开 Codex Hooks 管理；应用不会替你自动信任。"
                        : hookTrustInstruction
                )
                    .font(MonitorDesktopTypography.body)
                    .foregroundStyle(MonitorDesktopTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(
                        store.isCodexSecurityReviewLaunching
                            ? "正在打开"
                            : (snapshot?.hookState.reviewActionTitle ?? "检查 Hooks 状态")
                    ) {
                        store.openCodexHookSecurityReview()
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isCodexSecurityReviewLaunching)
                    Spacer()
                    Button("我已确认当前 Hook 已 Active") {
                        confirmsSecurityReviewCompletion = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if snapshot?.hookState == .waitingForFirstEvent {
                Text("当前 Hook 的 Active 状态已记录。请使用 Cmd + Q 完全退出 Codex，再重新打开并发送一条真实消息；连接仍需事件验证。")
                    .font(MonitorDesktopTypography.body)
                    .foregroundStyle(MonitorDesktopTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            setupDivider
            HStack(spacing: 8) {
                Button("返回") { step = .hooks }
                    .buttonStyle(.bordered)
                Spacer()
                Button(snapshot?.hookState == .connected ? "完成" : "稍后完成") {
                    finishOnboarding()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private var maintenanceDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("通知与任务状态连接均可按需开启。")
                .font(MonitorDesktopTypography.body)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
            permissionsGroup
                .modifier(MonitorDesktopReveal())
            appUpdateCard
                .modifier(MonitorDesktopReveal(delay: 0.04))
            environmentDetailsGroup
                .modifier(MonitorDesktopReveal(delay: 0.08))
            HStack(spacing: 10) {
                Button("重新运行引导") {
                    store.resetSetupOnboarding()
                    persistedStepRawValue = SetupOnboardingStep.welcome.rawValue
                    withAnimation(disclosureAnimation) { step = .welcome }
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 0)
                Button("刷新状态") { refreshPermissionStatus() }
                    .buttonStyle(.bordered)
            }
            .font(MonitorDesktopTypography.control)
            .padding(.horizontal, 2)
        }
    }

    private var permissionsGroup: some View {
        setupCard {
            Text("权限与连接")
                .font(MonitorDesktopTypography.cardTitle)
            permissionRow(
                title: "通知",
                detail: "额度恢复、重置确认与需要处理的任务提醒。"
            ) {
                HStack(spacing: 12) {
                    Text(notificationStatusTitle)
                        .foregroundStyle(notificationStatusColor)
                    notificationPermissionButton
                        .buttonStyle(.bordered)
                }
            }
            setupDivider
            permissionRow(
                title: "任务状态连接",
                detail: "通过 Codex Hooks 显示任务开始、等待批准与完成。"
            ) {
                HStack(spacing: 12) {
                    Text(displayedHookStateTitle)
                        .foregroundStyle(hookStateColor)
                    hookPrimaryAction
                }
            }
            hookFollowUp
        }
    }

    @ViewBuilder
    private var hookPrimaryAction: some View {
        if store.isCodexSetupWorking {
            ProgressView().controlSize(.small)
                .accessibilityLabel("正在更新 Hook 配置")
        } else {
            switch snapshot?.hookState.onboardingStepMode {
            case .install:
                Button(snapshot?.hookState == .updateRequired ? "更新 Hook…" : "安装 Hook…") {
                    confirmsHookInstall = true
                }
                .buttonStyle(.bordered)
            case .review:
                Button(store.isCodexSecurityReviewLaunching ? "正在打开" : "打开 Hooks 管理") {
                    store.openCodexHookSecurityReview()
                }
                .buttonStyle(.bordered)
                .disabled(store.isCodexSecurityReviewLaunching)
            case .advance:
                Button(store.isCodexSecurityReviewLaunching ? "正在打开" : "管理") {
                    store.openCodexHookSecurityReview()
                }
                .buttonStyle(.bordered)
                .disabled(store.isCodexSecurityReviewLaunching)
            case .deferOnly:
                Button("重新检查") { refreshPermissionStatus() }
                    .buttonStyle(.bordered)
            case .checking, .none:
                ProgressView().controlSize(.small)
                    .accessibilityLabel("正在检查任务状态连接")
            }
        }
    }

    @ViewBuilder
    private var hookFollowUp: some View {
        if snapshot?.hookState.needsTrustConfirmation == true {
            VStack(alignment: .leading, spacing: 9) {
                Text(hookTrustInstruction)
                    .fixedSize(horizontal: false, vertical: true)
                Button("我已在 Codex 确认 Active…") {
                    confirmsSecurityReviewCompletion = true
                }
                .buttonStyle(.bordered)
                .disabled(store.isCodexSetupWorking || store.isCodexSecurityReviewLaunching)
            }
            .font(MonitorDesktopTypography.metadata)
            .foregroundStyle(MonitorDesktopTheme.secondaryText)
        } else if snapshot?.hookState == .waitingForFirstEvent {
            Text("Active 状态已记录。请完全退出并重开 Codex，再发送一条真实消息以验证当前连接。")
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else if snapshot?.hookState.onboardingStepMode == .deferOnly {
            Text(hookEnvironmentInstruction)
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let date = snapshot?.lastConnectedAt {
            Text("\(snapshot?.hookState == .connected ? "最近真实事件" : "历史事件")：\(date.compactRelativeText)")
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(MonitorDesktopTheme.tertiaryText)
                .help(date.formatted(date: .abbreviated, time: .shortened))
        }
    }

    private var environmentDetailsGroup: some View {
        setupCard {
            DisclosureGroup("环境与配置", isExpanded: $environmentDetailsExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    environmentStatusRows
                    setupDivider
                    pathBlock("Hook 配置", path: snapshot?.hooksURL.path ?? "~/.codex/hooks.json")
                    pathBlock("稳定 Helper", path: snapshot?.installedHelperURL.path ?? "应用支持目录")
                    Text("安装和卸载前会备份并请求确认，只处理本插件的 Hook 定义，保留其他 Hooks。")
                        .font(MonitorDesktopTypography.metadata)
                        .foregroundStyle(MonitorDesktopTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button("查看备份") { store.revealCodexSetupBackups() }
                            .buttonStyle(.bordered)
                        Spacer(minLength: 0)
                        Menu("Hook 操作") {
                            Button(hookMaintenanceInstallTitle) { confirmsHookInstall = true }
                            Divider()
                            Button("卸载 Hook…", role: .destructive) { confirmsHookUninstall = true }
                                .disabled(snapshot?.hookState == .notInstalled)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(hookWriteActionsAreBlocked)
                    }
                }
                .padding(.top, 12)
                .modifier(MonitorDesktopReveal())
            }
            .font(MonitorDesktopTypography.rowTitle)
            .animation(disclosureAnimation, value: environmentDetailsExpanded)
        }
    }

    private var appUpdateCard: some View {
        setupCard {
            permissionRow(title: "应用更新", detail: "v\(store.appUpdateStatus.currentVersion) · Build \(store.appUpdateStatus.currentBuild) · \(appUpdateCheckedText)") {
                HStack(spacing: 12) {
                    Text(appUpdateStatusTitle)
                        .foregroundStyle(appUpdateStatusColor)
                    if store.appUpdateStatus.phase == .checking {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("正在检查应用更新")
                    } else if store.appUpdateStatus.phase == .updateAvailable {
                        Button(appUpdateDownloadTitle) { store.openAppUpdateDownload() }
                            .buttonStyle(.bordered)
                    } else {
                        Button("检查更新") { store.checkForAppUpdate(force: true) }
                            .buttonStyle(.bordered)
                    }
                }
            }
            if store.appUpdateStatus.phase == .updateAvailable,
               let release = store.appUpdateStatus.release {
                updateAvailableDetails(release)
            }
            if let message = store.appUpdateMessage ?? store.appUpdateStatus.message {
                Text(message)
                    .font(MonitorDesktopTypography.metadata)
                    .foregroundStyle(store.appUpdateStatus.phase == .failed ? .orange : MonitorDesktopTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func updateAvailableDetails(_ release: AppRelease) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            setupDivider
            Text("新版本 \(release.tagName)")
                .font(MonitorDesktopTypography.rowTitle)
            if !release.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(release.body)
                    .font(MonitorDesktopTypography.body)
                    .foregroundStyle(MonitorDesktopTheme.secondaryText)
                    .lineSpacing(2)
                    .lineLimit(4)
            }
            HStack(spacing: 10) {
                Button("查看版本说明") { store.openAppReleasePage() }
                    .buttonStyle(.borderless)
                Button("稍后提醒") { store.deferAppUpdate() }
                    .buttonStyle(.borderless)
                Spacer(minLength: 0)
            }
            .font(MonitorDesktopTypography.control)
            if let asset = store.appUpdateStatus.asset {
                DisclosureGroup("安装包详情", isExpanded: $updateDetailsExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 7) {
                            Label(AppUpdateArchitecture.current.displayName, systemImage: "desktopcomputer")
                            if asset.size > 0 {
                                Text("·")
                                Text(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))
                            }
                        }
                        if let digest = asset.digest {
                            Text(digest)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 10)
                    .modifier(MonitorDesktopReveal())
                }
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                .animation(disclosureAnimation, value: updateDetailsExpanded)
            }
        }
    }

    private func permissionRow<Actions: View>(
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                permissionLabel(title: title, detail: detail)
                    .frame(minWidth: 210, maxWidth: .infinity, alignment: .leading)
                actions().fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 10) {
                permissionLabel(title: title, detail: detail)
                HStack {
                    Spacer(minLength: 0)
                    actions().fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .font(MonitorDesktopTypography.control)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }

    private func permissionLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(MonitorDesktopTypography.rowTitle)
            Text(detail)
                .font(MonitorDesktopTypography.metadata)
                .foregroundStyle(MonitorDesktopTheme.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appUpdateStatusTitle: String {
        switch store.appUpdateStatus.phase {
        case .idle: return "尚未检查"
        case .checking: return "正在检查"
        case .upToDate: return "已是最新"
        case .updateAvailable: return "新版本可用"
        case .developmentBuild: return "开发版本"
        case .failed: return "检查失败"
        }
    }

    private var appUpdateStatusColor: Color {
        switch store.appUpdateStatus.phase {
        case .upToDate: return MonitorDesktopTheme.secondaryText
        case .updateAvailable: return MonitorDesktopTheme.secondaryText
        case .failed: return .orange
        case .checking: return MonitorDesktopTheme.secondaryText
        case .idle, .developmentBuild: return MonitorDesktopTheme.tertiaryText
        }
    }

    private var appUpdateCheckedText: String {
        guard let date = store.appUpdateStatus.checkedAt else {
            return store.appUpdateStatus.phase == .checking ? "正在连接 GitHub" : "尚未检查"
        }
        return "上次检查：\(date.compactRelativeText)"
    }

    private var appUpdateDownloadTitle: String {
        guard store.appUpdateStatus.asset != nil else { return "打开 Release" }
        return "下载安装包"
    }

    private var snapshot: CodexSetupSnapshot? { store.codexSetupSnapshot }

    private var hookStateColor: Color {
        CodexSetupPresentation.hookNeedsAttention(for: snapshot?.hookState)
            ? .orange : MonitorDesktopTheme.secondaryText
    }

    private var displayedHookStateTitle: String {
        if store.isCodexSetupWorking { return "正在更新配置" }
        if store.isCodexSecurityReviewLaunching { return "正在打开管理" }
        return CodexSetupPresentation.hookTitle(for: snapshot?.hookState)
    }

    private var environmentStatusRows: some View {
        VStack(spacing: 8) {
            setupStatusRow(
                "Codex CLI",
                value: environmentIsChecking ? "正在检查" : (snapshot?.codexExecutableURL == nil ? "未找到" : "可用"),
                color: !environmentIsChecking && snapshot?.codexExecutableURL == nil ? .orange : MonitorDesktopTheme.secondaryText
            )
            setupStatusRow(
                "Hook Helper",
                value: environmentIsChecking ? "正在检查" : (snapshot?.sourceHelperURL == nil ? "不可用" : "随应用提供"),
                color: !environmentIsChecking && snapshot?.sourceHelperURL == nil ? .orange : MonitorDesktopTheme.secondaryText
            )
            setupStatusRow(
                "Hooks 配置",
                value: configurationAssessment.title,
                color: configurationAssessment == .invalid || configurationAssessment == .blocked ? .orange : MonitorDesktopTheme.secondaryText
            )
        }
    }

    private var environmentIsChecking: Bool {
        snapshot == nil || snapshot?.hookState == .checking
    }

    private var configurationAssessment: CodexSetupConfigurationAssessment {
        CodexSetupPresentation.configurationAssessment(for: snapshot?.hookState)
    }

    private var hookWriteActionsAreBlocked: Bool {
        store.isCodexSetupWorking || store.isCodexSecurityReviewLaunching
            || snapshot == nil || snapshot?.hookState.onboardingStepMode == .checking
            || snapshot?.hookState.onboardingStepMode == .deferOnly
    }

    private var hookEnvironmentInstruction: String {
        switch snapshot?.hookState {
        case .codexUnavailable: return "未找到可用的 Codex CLI。确认 Codex 已安装后重新检查；当前无法安装任务状态连接。"
        case .helperUnavailable: return "安装包中的 Hook Helper 不可用。请检查应用安装，当前无法安装任务状态连接。"
        case .invalidHooksFile: return "Hooks 配置无法解析。为保护已有配置，当前不会执行安装或卸载。"
        default: return "请先完成环境检查。"
        }
    }

    private func refreshPermissionStatus() {
        store.refreshCodexSetup()
        store.refreshNotificationStatus()
    }

    private var hookInstallActionTitle: String {
        snapshot?.hookState == .updateRequired
            ? "备份并更新 Hook"
            : "备份并安装 Hook"
    }

    private var hookMaintenanceInstallTitle: String {
        if snapshot?.hookState == .notInstalled || snapshot?.hookState == .updateRequired {
            return hookInstallActionTitle + "…"
        }
        return "备份并重新安装 Hook…"
    }

    private var shouldShowSetupMessage: Bool {
        if store.isSetupOnboardingComplete { return true }
        return step == .hooks || step == .verify
    }

    private var notificationStatusTitle: String {
        switch store.quotaNotificationStatus {
        case .unknown: return "尚未确认"
        case .enabled: return "已允许"
        case .denied: return "已关闭"
        }
    }

    private var notificationStatusColor: Color {
        MonitorDesktopTheme.secondaryText
    }

    private var notificationActionDetail: String {
        switch store.quotaNotificationStatus {
        case .unknown:
            return "点击“允许通知”可向 macOS 请求授权，也可以跳过，稍后再开启。"
        case .enabled:
            return "通知已允许。可在系统设置中调整提醒样式与声音。"
        case .denied:
            return "通知已关闭。可在系统设置中重新允许，基础监控仍可正常使用。"
        }
    }

    @ViewBuilder
    private var notificationPermissionButton: some View {
        if store.quotaNotificationStatus == .unknown {
            Button("允许通知") { store.requestNotificationAuthorizationForSetup() }
        } else {
            Button("打开通知设置") { store.openNotificationSettings() }
        }
    }

    private var verificationDetail: String {
        if store.isCodexSecurityReviewLaunching {
            return "正在打开 Codex Hooks 管理。"
        }
        switch snapshot?.hookState {
        case .connected: return "当前 Hook 定义已收到真实事件，设置完成。"
        case .waitingForFirstEvent: return "Active 状态已记录，需要重启 Codex 并发送一条真实消息以验证连接。"
        case .trustStatusUnknown: return "App 尚未保存当前 Hook 的确认记录，请在 /hooks 检查是否为 Active。"
        case .securityReviewRequired: return "信任必须由你在 Codex 审核菜单中亲自确认。"
        case .notInstalled: return "尚未安装 Hook，可以返回上一步安装或稍后处理。"
        default: return "检查当前安装状态并完成剩余步骤。"
        }
    }

    private var hookTrustInstruction: String {
        switch snapshot?.hookState {
        case .trustStatusUnknown:
            return "Codex 会打开 /hooks。确认当前 Codex Monitor Hook 为 Active 后，回到 App 记录确认；如果出现审核菜单，请先完成信任。"
        case .securityReviewRequired:
            return "当前 Hook 定义与之前确认的定义不同。Codex 会打开 /hooks；请审核新定义并完成信任。"
        default:
            return "请在 Codex 的 /hooks 页面检查当前 Hook 状态。"
        }
    }

    private var disclosureAnimation: Animation? {
        reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1)
    }

    private func setupCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            MonitorDesktopTheme.cardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
                .strokeBorder(MonitorDesktopTheme.hairline, lineWidth: 0.7)
        }
    }

    private func setupHero(
        symbol: String,
        color: Color,
        title: String,
        detail: String
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 42, height: 42)
                .background(color.opacity(0.10), in: Circle())
            setupSectionTitle(title, detail: detail)
        }
    }

    private func setupSectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MonitorDesktopTypography.cardTitle)
            Text(detail)
                .font(MonitorDesktopTypography.body)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupBullet(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(MonitorDesktopTypography.rowTitle)
            .foregroundStyle(MonitorDesktopTheme.secondaryText)
    }

    private func setupStatusRow(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(MonitorDesktopTypography.rowTitle)
            Spacer()
            Circle().fill(color).frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(value)
                .font(MonitorDesktopTypography.control)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }

    private func pathBlock(_ title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(MonitorDesktopTypography.metadataMedium)
                .foregroundStyle(MonitorDesktopTheme.tertiaryText)
            Text(path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path,
                with: "~"
            ))
            .font(.system(size: 12, weight: .regular, design: .monospaced))
            .foregroundStyle(MonitorDesktopTheme.secondaryText)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .help(path)
        }
    }

    private var setupDivider: some View {
        Divider().overlay(MonitorDesktopTheme.separator)
    }

    private func navigationButtons(nextDisabled: Bool = false) -> some View {
        HStack(spacing: 8) {
            Button("返回") { rewind() }
                .buttonStyle(.bordered)
                .disabled(step == .welcome)
            Spacer()
            Button("下一步") { advance() }
                .buttonStyle(.borderedProminent)
                .disabled(nextDisabled)
        }
    }

    private func advance() {
        guard let next = SetupOnboardingStep(rawValue: step.rawValue + 1) else {
            finishOnboarding()
            return
        }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            step = next
        }
    }

    private func rewind() {
        guard let previous = SetupOnboardingStep(rawValue: step.rawValue - 1) else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
            step = previous
        }
    }

    private func finishOnboarding() {
        persistedStepRawValue = SetupOnboardingStep.welcome.rawValue
        step = .welcome
        store.completeSetupOnboarding()
    }

    private func reconcileStepWithSetupState() {
        guard step == .verify else { return }
        if snapshot?.hookState == .notInstalled
            || snapshot?.hookState == .updateRequired {
            step = .hooks
        }
    }

    private func setupMessage(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(MonitorDesktopTheme.cyanAccent)
            Text(message)
                .font(MonitorDesktopTypography.body)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            MonitorDesktopTheme.cyanAccent.opacity(0.07),
            in: RoundedRectangle(cornerRadius: MonitorGeometry.compactRadius, style: .continuous)
        )
    }
}
