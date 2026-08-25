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
            Text("将备份并合并 ~/.codex/hooks.json，保留其他已有 Hooks；Helper 会复制到应用支持目录的稳定路径。安装后仍需由你在 Codex 审核菜单中选择“2. Trust all and continue”并按 Enter。")
        }
        .alert("卸载 Codex Monitor Hooks？", isPresented: $confirmsHookUninstall) {
            Button("取消", role: .cancel) {}
            Button("备份并卸载", role: .destructive) {
                store.uninstallCodexSetupHooks()
            }
        } message: {
            Text("将先备份 ~/.codex/hooks.json，再只移除命令中属于 CodexMonitorHook 的 Handler；不会删除其他 Hooks。")
        }
        .alert("确认已完成 Codex 安全审核？", isPresented: $confirmsSecurityReviewCompletion) {
            Button("取消", role: .cancel) {}
            Button("已选择信任") {
                store.confirmCodexHookSecurityReview()
            }
        } message: {
            Text("只有你已经在 Codex 菜单中选择“2. Trust all and continue”并按 Enter 后才确认。此操作只记录当前安装哈希；最终仍需首条真实 Hook 事件验证。")
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
                if store.isCodexSecurityReviewRunning {
                    Button("审核进行中") { step = .verify }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("进入安全审核") { step = .verify }
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
                "安全审核与连接验证",
                detail: verificationDetail
            )
            setupDivider
            setupStatusRow(
                "Hook 状态",
                value: displayedHookStateTitle,
                color: hookStateColor
            )
            if snapshot?.hookState == .securityReviewRequired {
                Text(
                    store.isCodexSecurityReviewRunning
                        ? "安全审核窗口已经打开。请选择“2. Trust all and continue”，按 Enter 确认，然后回到这里继续。"
                        : "打开后，Codex 会显示 Hooks 审核菜单。请选择“2. Trust all and continue”并按 Enter；应用不会替你自动信任。"
                )
                    .font(MonitorTypography.body)
                    .foregroundStyle(MonitorTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isCodexSecurityReviewRunning {
                    Button("我已完成安全审核") {
                        confirmsSecurityReviewCompletion = true
                    }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("打开 Codex 安全审核") {
                        store.openCodexHookSecurityReview()
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
            setupCard {
                setupHero(
                    symbol: hookStateSymbol,
                    color: hookStateColor,
                    title: "安装与权限",
                    detail: "随时检查通知、Hook 定义、安全审核与真实连接状态。"
                )
                setupDivider
                setupStatusRow("系统通知", value: notificationStatusTitle, color: notificationStatusColor)
                setupStatusRow("Codex Hooks", value: snapshot?.hookState.title ?? "正在检查", color: hookStateColor)
                if let date = snapshot?.lastConnectedAt {
                    setupStatusRow("最近真实事件", value: date.compactRelativeText, color: .green)
                }
            }

            setupCard {
                setupSectionTitle("Hook 管理", detail: "任何真实写入都只在你点击确认后执行。")
                setupDivider
                pathBlock("配置文件", path: snapshot?.hooksURL.path ?? "~/.codex/hooks.json")
                pathBlock("Helper", path: snapshot?.installedHelperURL.path ?? "应用支持目录")
                setupDivider
                HStack(spacing: 8) {
                    Button("查看备份") { store.revealCodexSetupBackups() }
                        .buttonStyle(.bordered)
                    Spacer()
                    if snapshot?.hookState == .securityReviewRequired {
                        Button("打开安全审核") { store.openCodexHookSecurityReview() }
                            .buttonStyle(.borderedProminent)
                    }
                    Button("重新安装") { confirmsHookInstall = true }
                        .buttonStyle(.bordered)
                    Button("卸载 Hook") { confirmsHookUninstall = true }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
            }

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

    private var snapshot: CodexSetupSnapshot? { store.codexSetupSnapshot }

    private var hookStateColor: Color {
        if store.isCodexSecurityReviewRunning { return MonitorTheme.cyanAccent }
        switch snapshot?.hookState {
        case .connected: return .green
        case .waitingForFirstEvent, .securityReviewRequired: return .orange
        case .notInstalled, .checking, .none: return MonitorTheme.tertiaryText
        case .updateRequired: return .orange
        case .codexUnavailable, .helperUnavailable, .invalidHooksFile: return .red
        }
    }

    private var displayedHookStateTitle: String {
        store.isCodexSecurityReviewRunning
            ? "安全审核进行中"
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
        if store.isCodexSecurityReviewRunning {
            return "安全审核窗口已打开，等待你在正确的 Hooks 页面确认。"
        }
        switch snapshot?.hookState {
        case .connected: return "Hook 已通过首条真实事件验证，设置完成。"
        case .waitingForFirstEvent: return "审核完成后，需要重启 Codex 并发送一条真实消息。"
        case .securityReviewRequired: return "信任必须由你在 Codex 审核菜单中亲自确认。"
        case .notInstalled: return "尚未安装 Hook，可以返回上一步安装或稍后处理。"
        default: return "检查当前安装状态并完成剩余步骤。"
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
