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

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 12) {
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
            .padding(.bottom, 4)
        }
        .onAppear {
            step = SetupOnboardingStep(rawValue: persistedStepRawValue) ?? .welcome
            store.refreshCodexSetup()
            store.checkForAppUpdate(force: false)
            reconcileStepWithSetupState()
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
                                ? MonitorTheme.selection
                                : MonitorTheme.controlFill
                        )
                        .frame(height: 4)
                    Text(item.title)
                        .font(MonitorTypography.metadata)
                        .foregroundStyle(
                            item == step
                                ? MonitorTheme.primaryText
                                : MonitorTheme.faintText
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
                detail: "完成通知和可选 Hooks 设置，让额度、任务阶段与会话状态形成完整闭环。"
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
            setupSectionTitle("环境检查", detail: "这一页只读取状态，不修改任何文件。")
            setupDivider
            setupStatusRow(
                "Codex CLI",
                value: snapshot?.codexExecutableURL == nil ? "未找到" : "可用",
                color: snapshot?.codexExecutableURL == nil ? .orange : .green
            )
            setupStatusRow(
                "Hook Helper",
                value: snapshot?.sourceHelperURL == nil ? "缺失" : "架构随 App 提供",
                color: snapshot?.sourceHelperURL == nil ? .orange : .green
            )
            setupStatusRow(
                "Hooks 配置",
                value: snapshot?.hookState == .invalidHooksFile ? "无法解析" : "可安全检查",
                color: snapshot?.hookState == .invalidHooksFile ? .orange : .green
            )
            setupDivider
            pathBlock("Hook 配置", path: snapshot?.hooksURL.path ?? "~/.codex/hooks.json")
            pathBlock("稳定 Helper", path: snapshot?.installedHelperURL.path ?? "应用支持目录")
            navigationButtons(nextDisabled: snapshot == nil)
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
            Text("只有点击“允许通知”后才会触发 macOS 授权提示。选择跳过后，可随时从安装与权限页面重新开启。")
                .font(MonitorTypography.body)
                .foregroundStyle(MonitorTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            setupDivider
            HStack(spacing: 8) {
                Button("返回") { rewind() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("跳过") { advance() }
                    .buttonStyle(.bordered)
                if store.quotaNotificationStatus != .enabled {
                    Button("允许通知") {
                        store.requestNotificationAuthorizationForSetup()
                    }
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
                    .font(MonitorTypography.rowTitle)
                Text("• 备份并合并 ~/.codex/hooks.json\n• 保留其他已有 Hooks\n• 安装 9 类当前用户事件，单次同步等待上限 2 秒\n• Helper 只写入一个小型本地事件，不执行网络请求")
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.secondaryText)
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
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.secondaryText)
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
                Text("安全审核已经完成。请使用 Cmd + Q 完全退出 Codex，再重新打开并发送一条真实消息；Codex Monitor 不会创建测试会话。")
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else if snapshot?.hookState == .connected {
                Label("连接已经通过真实 Hook 事件验证", systemImage: "checkmark.circle.fill")
                    .font(MonitorTypography.rowTitle)
                    .foregroundStyle(.green)
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
        VStack(spacing: 12) {
            maintenanceOverviewCard
            appUpdateCard
            maintenanceEvidenceCard
            hookManagementCard

            HStack {
                Button("重新运行首次引导") {
                    store.resetSetupOnboarding()
                    persistedStepRawValue = SetupOnboardingStep.welcome.rawValue
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                        step = .welcome
                    }
                }
                .buttonStyle(.plain)
                .font(MonitorTypography.control)
                .foregroundStyle(MonitorTheme.cyanAccent)
                Spacer()
                Button("刷新状态") { store.refreshCodexSetup() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 2)
        }
    }

    private var maintenanceOverviewCard: some View {
        setupCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(maintenanceOverallColor.opacity(0.12))
                    Image(systemName: maintenanceOverallSymbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(maintenanceOverallColor)
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(maintenanceOverallTitle)
                        .font(MonitorTypography.cardTitle)
                        .foregroundStyle(MonitorTheme.primaryText)
                    Text(maintenanceOverallDetail)
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 10)

                Text(maintenanceOverallBadge)
                    .font(MonitorTypography.control)
                    .foregroundStyle(maintenanceOverallColor)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        maintenanceOverallColor.opacity(0.10),
                        in: Capsule()
                    )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(maintenanceOverallTitle)
            .accessibilityValue(maintenanceOverallDetail)
        }
    }

    private var maintenanceEvidenceCard: some View {
        setupCard {
            setupSectionTitle(
                "当前证据",
                detail: "以下状态均为只读检查，不会修改通知、Hook 或配置文件。"
            )
            setupDivider
            setupStatusRow(
                "系统通知",
                value: notificationStatusTitle,
                color: notificationStatusColor
            )
            setupStatusRow(
                "Codex Hooks",
                value: snapshot?.hookState.title ?? "正在检查",
                color: hookStateColor
            )
            if let date = snapshot?.lastConnectedAt {
                setupStatusRow(
                    "最近真实事件",
                    value: date.compactRelativeText,
                    color: .green
                )
            }
            setupDivider
            pathBlock(
                "配置文件",
                path: snapshot?.hooksURL.path ?? "~/.codex/hooks.json"
            )
            pathBlock(
                "Helper",
                path: snapshot?.installedHelperURL.path ?? "应用支持目录"
            )
        }
    }

    private var hookManagementCard: some View {
        setupCard {
            setupSectionTitle(
                "Hook 管理",
                detail: "以下操作可能写入配置；每次都会先备份，并在执行前再次确认。"
            )
            setupDivider
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.top, 1)
                Text("重新安装只会合并 CodexMonitorHook；卸载只会移除属于它的 Handler，不会删除其他 Hooks。")
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                Color.orange.opacity(0.055),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            setupDivider
            HStack(spacing: 8) {
                Button("查看备份") { store.revealCodexSetupBackups() }
                    .buttonStyle(.bordered)
                Spacer()
                if snapshot?.hookState.needsTrustConfirmation == true {
                    Button(
                        store.isCodexSecurityReviewLaunching
                            ? "正在打开"
                            : (snapshot?.hookState.reviewActionTitle ?? "检查 Hooks 状态")
                    ) {
                        store.openCodexHookSecurityReview()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.isCodexSecurityReviewLaunching)
                    Button("确认已 Active") {
                        confirmsSecurityReviewCompletion = true
                    }
                    .buttonStyle(.bordered)
                } else if snapshot?.hookState == .waitingForFirstEvent
                    || snapshot?.hookState == .connected {
                    Button("打开 Hooks 管理") {
                        store.openCodexHookSecurityReview()
                    }
                    .buttonStyle(.bordered)
                }
                Menu {
                    Button("重新安装 Hook") { confirmsHookInstall = true }
                    Divider()
                    Button("卸载 Hook", role: .destructive) {
                        confirmsHookUninstall = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .help("更多 Hook 操作")
            }
        }
    }

    private var appUpdateCard: some View {
        let status = store.appUpdateStatus
        return setupCard {
            HStack(spacing: 11) {
                AppUpdateStatusIcon(
                    phase: status.phase,
                    color: appUpdateStatusColor,
                    reduceMotion: reduceMotion
                )
                setupSectionTitle(
                    "应用更新",
                    detail: "从 GitHub Latest Release 检查新版本，并选择适用于此 Mac 的 DMG。"
                )
                Spacer(minLength: 8)
                Text(appUpdateStatusTitle)
                    .font(MonitorTypography.control)
                    .foregroundStyle(appUpdateStatusColor)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(
                        appUpdateStatusColor.opacity(0.10),
                        in: Capsule()
                    )
            }

            setupDivider

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("当前版本")
                        .font(MonitorTypography.metadataMedium)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                    Text("v\(status.currentVersion) (Build \(status.currentBuild))")
                        .font(AstaSans.semiBold(10.5))
                }
                Spacer()
                if let release = status.release {
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("GitHub Release")
                            .font(MonitorTypography.metadataMedium)
                            .foregroundStyle(MonitorTheme.tertiaryText)
                        Text(release.tagName)
                            .font(AstaSans.semiBold(10.5))
                            .foregroundStyle(
                                status.phase == .updateAvailable
                                    ? MonitorTheme.cyanAccent
                                    : MonitorTheme.primaryText
                            )
                    }
                }
            }

            if status.phase == .updateAvailable, let release = status.release {
                if !release.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(release.body)
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.secondaryText)
                        .lineSpacing(2)
                        .lineLimit(4)
                }
                if let asset = status.asset {
                    HStack(spacing: 7) {
                        Label(AppUpdateArchitecture.current.displayName, systemImage: "desktopcomputer")
                        if asset.size > 0 {
                            Text("·")
                            Text(ByteCountFormatter.string(fromByteCount: asset.size, countStyle: .file))
                        }
                        if let digest = asset.digest {
                            Text("·")
                            Text(shortUpdateDigest(digest))
                                .monospaced()
                        }
                    }
                    .font(MonitorTypography.metadata)
                    .foregroundStyle(MonitorTheme.tertiaryText)
                    .lineLimit(1)
                }
            }

            if let message = store.appUpdateMessage ?? status.message {
                Text(message)
                    .font(MonitorTypography.body)
                    .foregroundStyle(status.phase == .failed ? Color.orange : MonitorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            setupDivider

            HStack(spacing: 8) {
                Text(appUpdateCheckedText)
                    .font(MonitorTypography.metadata)
                    .foregroundStyle(MonitorTheme.faintText)
                Spacer()
                if status.phase == .updateAvailable {
                    Button("查看说明") { store.openAppReleasePage() }
                        .buttonStyle(.bordered)
                    Button("稍后提醒") { store.deferAppUpdate() }
                        .buttonStyle(.bordered)
                    Button(appUpdateDownloadTitle) { store.openAppUpdateDownload() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button(status.phase == .checking ? "正在检查" : "检查更新") {
                        store.checkForAppUpdate(force: true)
                    }
                    .buttonStyle(.bordered)
                    .disabled(status.phase == .checking)
                }
            }
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
        case .upToDate: return .green
        case .updateAvailable: return MonitorTheme.cyanAccent
        case .failed: return .orange
        case .checking: return MonitorTheme.selection
        case .idle, .developmentBuild: return MonitorTheme.tertiaryText
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
        switch AppUpdateArchitecture.current {
        case .arm64: return "下载 arm64 DMG"
        case .x86_64: return "下载 x86_64 DMG"
        case .unknown: return "下载 DMG"
        }
    }

    private func shortUpdateDigest(_ digest: String) -> String {
        guard digest.hasPrefix("sha256:") else { return digest }
        let value = digest.dropFirst("sha256:".count)
        return "SHA-256 \(value.prefix(8))…"
    }

    private var snapshot: CodexSetupSnapshot? { store.codexSetupSnapshot }

    private var maintenanceOverallTitle: String {
        guard let state = snapshot?.hookState else { return "正在检查安装状态" }
        if state == .connected,
           store.quotaNotificationStatus == .enabled {
            return "安装状态正常"
        }
        switch state {
        case .connected:
            return "基础连接正常"
        case .waitingForFirstEvent:
            return "等待真实连接验证"
        case .trustStatusUnknown, .securityReviewRequired:
            return "需要确认 Hook 状态"
        case .notInstalled, .updateRequired:
            return "Hook 需要处理"
        case .codexUnavailable, .helperUnavailable, .invalidHooksFile:
            return "安装环境异常"
        case .checking:
            return "正在检查安装状态"
        }
    }

    private var maintenanceOverallDetail: String {
        guard let state = snapshot?.hookState else {
            return "正在读取通知、Hook 定义和真实连接证据。"
        }
        if state == .connected,
           store.quotaNotificationStatus == .enabled {
            return "系统通知已允许，Codex Hooks 已通过真实事件验证。"
        }
        if state == .connected {
            return "Codex Hooks 已连接；系统通知当前为\(notificationStatusTitle)。"
        }
        return "系统通知：\(notificationStatusTitle)；Codex Hooks：\(state.title)。"
    }

    private var maintenanceOverallColor: Color {
        guard let state = snapshot?.hookState else {
            return MonitorTheme.tertiaryText
        }
        if state == .connected,
           store.quotaNotificationStatus == .enabled {
            return .green
        }
        switch state {
        case .codexUnavailable, .helperUnavailable, .invalidHooksFile:
            return .red
        case .connected, .waitingForFirstEvent, .trustStatusUnknown,
             .securityReviewRequired, .notInstalled, .updateRequired:
            return .orange
        case .checking:
            return MonitorTheme.tertiaryText
        }
    }

    private var maintenanceOverallSymbol: String {
        guard let state = snapshot?.hookState else {
            return "arrow.triangle.2.circlepath"
        }
        if state == .connected,
           store.quotaNotificationStatus == .enabled {
            return "checkmark.shield.fill"
        }
        switch state {
        case .codexUnavailable, .helperUnavailable, .invalidHooksFile:
            return "exclamationmark.shield.fill"
        case .checking:
            return "arrow.triangle.2.circlepath"
        default:
            return "exclamationmark.triangle.fill"
        }
    }

    private var maintenanceOverallBadge: String {
        guard let state = snapshot?.hookState else { return "检查中" }
        if state == .connected,
           store.quotaNotificationStatus == .enabled {
            return "全部正常"
        }
        switch state {
        case .connected:
            return "通知待处理"
        case .waitingForFirstEvent:
            return "待验证"
        case .trustStatusUnknown, .securityReviewRequired:
            return "待确认"
        case .notInstalled:
            return "未安装"
        case .updateRequired:
            return "需要更新"
        case .codexUnavailable, .helperUnavailable, .invalidHooksFile:
            return "异常"
        case .checking:
            return "检查中"
        }
    }

    private var hookStateColor: Color {
        if store.isCodexSecurityReviewLaunching { return MonitorTheme.cyanAccent }
        switch snapshot?.hookState {
        case .connected: return .green
        case .waitingForFirstEvent, .trustStatusUnknown, .securityReviewRequired: return .orange
        case .notInstalled, .checking, .none: return MonitorTheme.tertiaryText
        case .updateRequired: return .orange
        case .codexUnavailable, .helperUnavailable, .invalidHooksFile: return .red
        }
    }

    private var displayedHookStateTitle: String {
        store.isCodexSecurityReviewLaunching
            ? "正在打开 Hooks 管理"
            : (snapshot?.hookState.title ?? "正在检查")
    }

    private var hookInstallActionTitle: String {
        snapshot?.hookState == .updateRequired
            ? "备份并更新 Hook"
            : "备份并安装 Hook"
    }

    private var shouldShowSetupMessage: Bool {
        if store.isSetupOnboardingComplete { return true }
        return step == .hooks || step == .verify
    }

    private var hookStateSymbol: String {
        switch snapshot?.hookState {
        case .connected: return "checkmark.shield.fill"
        case .waitingForFirstEvent: return "message.badge.waveform.fill"
        case .trustStatusUnknown: return "questionmark.shield.fill"
        case .securityReviewRequired: return "person.badge.key.fill"
        default: return "wrench.and.screwdriver.fill"
        }
    }

    private var notificationStatusTitle: String {
        switch store.quotaNotificationStatus {
        case .unknown: return "尚未确认"
        case .enabled: return "已允许"
        case .denied: return "已关闭"
        }
    }

    private var notificationStatusColor: Color {
        switch store.quotaNotificationStatus {
        case .enabled: return .green
        case .denied: return .orange
        case .unknown: return MonitorTheme.tertiaryText
        }
    }

    private var verificationDetail: String {
        if store.isCodexSecurityReviewLaunching {
            return "正在打开 Codex Hooks 管理。"
        }
        switch snapshot?.hookState {
        case .connected: return "Hook 已通过首条真实事件验证，设置完成。"
        case .waitingForFirstEvent: return "审核完成后，需要重启 Codex 并发送一条真实消息。"
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

    private func setupCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: MonitorGeometry.cardRadius, style: .continuous)
                .strokeBorder(MonitorTheme.separator, lineWidth: 0.7)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(AstaSans.semiBold(12))
            Text(detail)
                .font(MonitorTypography.body)
                .foregroundStyle(MonitorTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func setupBullet(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(MonitorTypography.rowTitle)
            .foregroundStyle(MonitorTheme.secondaryText)
    }

    private func setupStatusRow(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(MonitorTypography.rowTitle)
            Spacer()
            Circle().fill(color).frame(width: 5, height: 5)
            Text(value)
                .font(MonitorTypography.control)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 25)
    }

    private func pathBlock(_ title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(MonitorTypography.metadataMedium)
                .foregroundStyle(MonitorTheme.tertiaryText)
            Text(path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path,
                with: "~"
            ))
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(MonitorTheme.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
        }
    }

    private var setupDivider: some View {
        Divider().overlay(MonitorTheme.separator)
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
                .foregroundStyle(MonitorTheme.cyanAccent)
            Text(message)
                .font(MonitorTypography.body)
                .foregroundStyle(MonitorTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            MonitorTheme.cyanAccent.opacity(0.07),
            in: RoundedRectangle(cornerRadius: MonitorGeometry.compactRadius, style: .continuous)
        )
    }
}

private struct AppUpdateStatusIcon: View {
    let phase: AppUpdatePhase
    let color: Color
    let reduceMotion: Bool

    @ViewBuilder
    var body: some View {
        switch phase {
        case .checking where !reduceMotion:
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                let progress = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.0)
                icon("arrow.triangle.2.circlepath")
                    .rotationEffect(.degrees(progress * 360))
            }
        case .updateAvailable where !reduceMotion:
            TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { context in
                let progress = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.6) / 1.6
                let wave = progress < 0.5 ? progress * 2 : (1 - progress) * 2
                icon("arrow.down.circle.fill")
                    .scaleEffect(1 + wave * 0.07)
                    .shadow(color: color.opacity(0.18 + wave * 0.22), radius: 5 + wave * 3)
            }
        case .upToDate:
            icon("checkmark.circle.fill")
        case .updateAvailable:
            icon("arrow.down.circle.fill")
        case .failed:
            icon("exclamationmark.triangle.fill")
        case .developmentBuild:
            icon("hammer.circle.fill")
        case .idle, .checking:
            icon("arrow.triangle.2.circlepath")
        }
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 40, height: 40)
            .background(color.opacity(0.09), in: Circle())
    }
}
