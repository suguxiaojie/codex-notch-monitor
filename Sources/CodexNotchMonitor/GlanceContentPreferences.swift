import Foundation
import SwiftUI

extension Notification.Name {
    static let glanceSurfaceOpacityDidChange = Notification.Name(
        "CodexMonitor.glanceSurfaceOpacityDidChange"
    )
}

enum GlanceContentPreferenceKey {
    static let showPrimaryQuota = "glance.content.primaryQuota"
    static let showSparkQuota = "glance.content.sparkQuota"
    static let showCostEstimate = "glance.content.costEstimate"
    static let showCreditBalance = "glance.content.creditBalance"
    static let showDailyTokens = "glance.content.dailyTokens"
    static let showThirtyDayTokens = "glance.content.thirtyDayTokens"
    static let showTokenActivity = "glance.content.tokenActivity"
    static let showResetEntry = "glance.content.resetEntry"
    static let surfaceOpacity = "glance.surfaceOpacity"
}

struct GlanceContentPreferences: Equatable {
    var showPrimaryQuota: Bool
    var showSparkQuota: Bool
    var showCostEstimate: Bool
    var showCreditBalance: Bool
    var showDailyTokens: Bool
    var showThirtyDayTokens: Bool
    var showTokenActivity: Bool
    var showResetEntry: Bool
    var surfaceOpacity: Double

    static let defaults = GlanceContentPreferences(
        showPrimaryQuota: true,
        showSparkQuota: true,
        showCostEstimate: true,
        showCreditBalance: true,
        showDailyTokens: true,
        showThirtyDayTokens: true,
        showTokenActivity: true,
        showResetEntry: true,
        surfaceOpacity: 0.38
    )

    static func load(from defaults: UserDefaults = .standard) -> Self {
        let registered = Self.defaults
        return Self(
            showPrimaryQuota: defaults.object(forKey: GlanceContentPreferenceKey.showPrimaryQuota) as? Bool
                ?? registered.showPrimaryQuota,
            showSparkQuota: defaults.object(forKey: GlanceContentPreferenceKey.showSparkQuota) as? Bool
                ?? registered.showSparkQuota,
            showCostEstimate: defaults.object(forKey: GlanceContentPreferenceKey.showCostEstimate) as? Bool
                ?? registered.showCostEstimate,
            showCreditBalance: defaults.object(forKey: GlanceContentPreferenceKey.showCreditBalance) as? Bool
                ?? registered.showCreditBalance,
            showDailyTokens: defaults.object(forKey: GlanceContentPreferenceKey.showDailyTokens) as? Bool
                ?? registered.showDailyTokens,
            showThirtyDayTokens: defaults.object(forKey: GlanceContentPreferenceKey.showThirtyDayTokens) as? Bool
                ?? registered.showThirtyDayTokens,
            showTokenActivity: defaults.object(forKey: GlanceContentPreferenceKey.showTokenActivity) as? Bool
                ?? registered.showTokenActivity,
            showResetEntry: defaults.object(forKey: GlanceContentPreferenceKey.showResetEntry) as? Bool
                ?? registered.showResetEntry,
            surfaceOpacity: min(
                0.90,
                max(
                    0.10,
                    defaults.object(forKey: GlanceContentPreferenceKey.surfaceOpacity) as? Double
                        ?? registered.surfaceOpacity
                )
            )
        )
    }

    func preferredHeight(
        primaryQuotaWindowCount: Int,
        supportingQuotaWindowCount: Int
    ) -> CGFloat {
        var height: CGFloat = 161
        if showPrimaryQuota {
            height += 24 + CGFloat(max(1, primaryQuotaWindowCount)) * 55
        }
        if showSparkQuota && supportingQuotaWindowCount > 0 {
            height += 42
        }
        if showCostEstimate { height += 139 }
        if showCreditBalance { height += 31 }
        if showDailyTokens { height += 31 }
        if showThirtyDayTokens { height += 31 }
        if showTokenActivity { height += 68 }
        if showResetEntry { height += 55 }
        return min(GlanceLayout.height, max(230, height))
    }
}

private enum GlanceSettingsSection: String, CaseIterable, Identifiable {
    case content = "内容"
    case appearance = "外观"

    var id: String { rawValue }
}

struct GlanceContentSettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(GlanceContentPreferenceKey.showPrimaryQuota) private var showPrimaryQuota = true
    @AppStorage(GlanceContentPreferenceKey.showSparkQuota) private var showSparkQuota = true
    @AppStorage(GlanceContentPreferenceKey.showCostEstimate) private var showCostEstimate = true
    @AppStorage(GlanceContentPreferenceKey.showCreditBalance) private var showCreditBalance = true
    @AppStorage(GlanceContentPreferenceKey.showDailyTokens) private var showDailyTokens = true
    @AppStorage(GlanceContentPreferenceKey.showThirtyDayTokens) private var showThirtyDayTokens = true
    @AppStorage(GlanceContentPreferenceKey.showTokenActivity) private var showTokenActivity = true
    @AppStorage(GlanceContentPreferenceKey.showResetEntry) private var showResetEntry = true
    @AppStorage(GlanceContentPreferenceKey.surfaceOpacity) private var surfaceOpacity = 0.38
    @State private var isAdjustingOpacity = false
    @State private var selectedSection = GlanceSettingsSection.content

    var body: some View {
        VStack(spacing: 0) {
            previewStatusBar

            Picker("面板设置分组", selection: $selectedSection) {
                ForEach(GlanceSettingsSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityLabel("面板设置分组")
            .controlSize(.regular)
            .frame(maxWidth: 320)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            divider

            ScrollView(.vertical, showsIndicators: true) {
                Group {
                    if selectedSection == .content {
                        contentSettings
                    } else {
                        appearanceSettings
                    }
                }
                .id(selectedSection)
                .transition(.opacity)
                .frame(maxWidth: 780)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
            .scrollDisabled(isAdjustingOpacity)
        }
        .font(MonitorDesktopTypography.body)
        .foregroundStyle(MonitorDesktopTheme.primaryText)
        .animation(
            reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.3, dampingFraction: 1),
            value: selectedSection
        )
        .onDisappear { isAdjustingOpacity = false }
        .onChange(of: surfaceOpacity) { opacity in
            NotificationCenter.default.post(
                name: .glanceSurfaceOpacityDidChange,
                object: opacity
            )
        }
    }

    private var previewStatusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(MonitorDesktopTheme.cyanAccent)
                .frame(width: 36, height: 36)
                .background(
                    MonitorDesktopTheme.cyanAccent.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("菜单栏面板预览")
                    .font(MonitorDesktopTypography.cardTitle)
                    .foregroundStyle(MonitorDesktopTheme.primaryText)
                Text("预览显示在菜单栏旁，设置会立即生效。")
                    .font(MonitorDesktopTypography.body)
                    .foregroundStyle(MonitorDesktopTheme.tertiaryText)
            }
            Spacer(minLength: 10)
            Text("已启用 \(visibleContentCount) / 8 项")
                .font(MonitorDesktopTypography.control)
                .foregroundStyle(MonitorDesktopTheme.secondaryText)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(MonitorDesktopTheme.subtleCardFill)
        .overlay(alignment: .bottom) {
            divider
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("菜单栏面板实时预览")
        .accessibilityValue("已启用 \(visibleContentCount) 项内容；有对应数据时显示")
    }

    private var contentSettings: some View {
        VStack(spacing: 20) {
            settingsGroup(title: "额度") {
                contentRow(
                    title: "Codex 额度窗口",
                    detail: "显示 5 小时、每周及其他可用额度窗口。",
                    isOn: $showPrimaryQuota
                )
                divider
                contentRow(
                    title: "其他模型额度",
                    detail: "有数据时显示 Spark 等模型剩余额度最少的窗口摘要。",
                    isOn: $showSparkQuota
                )
                divider
                contentRow(
                    title: "Credits 余额",
                    detail: "显示当前登录账号的可用 Credits 余额。",
                    isOn: $showCreditBalance
                )
                divider
                contentRow(
                    title: "额度重置入口",
                    detail: "显示额度卡剩余次数、到期时间和重置入口。",
                    isOn: $showResetEntry
                )
            }
            .modifier(MonitorDesktopReveal())

            settingsGroup(title: "用量") {
                contentRow(
                    title: "最近一天 Token",
                    detail: "显示最近一个统计日的 Token 用量。",
                    isOn: $showDailyTokens
                )
                divider
                contentRow(
                    title: "30 日 Token",
                    detail: "显示最近 30 个统计日的 Token 总量。",
                    isOn: $showThirtyDayTokens
                )
                divider
                contentRow(
                    title: "Token 活动图表",
                    detail: "查看最近一周、一个月、三个月或半年的 Token 活动。",
                    isOn: $showTokenActivity
                )
            }
            .modifier(MonitorDesktopReveal(delay: 0.04))

            settingsGroup(title: "成本") {
                contentRow(
                    title: "成本估算图表",
                    detail: "按参考 API 价格估算用量成本，支持切换统计周期。",
                    isOn: $showCostEstimate
                )
            }
            .modifier(MonitorDesktopReveal(delay: 0.08))
        }
    }

    private var appearanceSettings: some View {
        VStack(spacing: 14) {
            opacityCard
                .modifier(MonitorDesktopReveal())
            Text("背景不透明度只影响菜单栏面板。调整时可在顶部菜单栏旁查看效果。")
                .font(MonitorDesktopTypography.body)
                .foregroundStyle(MonitorDesktopTheme.tertiaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 2)
                .modifier(MonitorDesktopReveal(delay: 0.04))
        }
    }

    private var visibleContentCount: Int {
        [
            showPrimaryQuota,
            showSparkQuota,
            showCostEstimate,
            showCreditBalance,
            showDailyTokens,
            showThirtyDayTokens,
            showTokenActivity,
            showResetEntry,
        ].filter { $0 }.count
    }

    private func settingsGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(MonitorDesktopTypography.cardTitle)
                .foregroundStyle(MonitorDesktopTheme.primaryText)
                .padding(.vertical, 16)
            divider
            content()
        }
        .padding(.horizontal, 18)
        .background(
            MonitorDesktopTheme.cardFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MonitorDesktopTheme.separator, lineWidth: 1)
        }
    }

    private func contentRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(MonitorDesktopTypography.rowTitle)
                    .foregroundStyle(MonitorDesktopTheme.primaryText)
                Text(detail)
                    .font(MonitorDesktopTypography.body)
                    .foregroundStyle(MonitorDesktopTheme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: MonitorDesktopTheme.selection))
                .controlSize(.regular)
                .accessibilityLabel(title)
                .accessibilityValue(isOn.wrappedValue ? "显示" : "隐藏")
        }
        .padding(.vertical, 14)
        .frame(minHeight: 68)
    }

    private var divider: some View {
        Divider().overlay(MonitorDesktopTheme.separator)
    }

    private var opacityCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("背景不透明度")
                        .font(MonitorDesktopTypography.cardTitle)
                    Text("数值越高，黑色背景越深。")
                        .font(MonitorDesktopTypography.body)
                        .foregroundStyle(MonitorDesktopTheme.tertiaryText)
                }
                Spacer()
                Text("\(Int((surfaceOpacity * 100).rounded()))%")
                    .font(MonitorDesktopTypography.rowTitle)
                    .monospacedDigit()
            }
            Slider(
                value: $surfaceOpacity,
                in: 0.10...0.90,
                step: 0.01,
                onEditingChanged: { isAdjustingOpacity = $0 }
            )
            .tint(MonitorDesktopTheme.selection)
            .accessibilityLabel("背景不透明度")
            .accessibilityValue("\(Int((surfaceOpacity * 100).rounded()))%")
            HStack {
                Text("更透明")
                Spacer()
                Text("更深")
            }
            .font(MonitorDesktopTypography.metadata)
            .foregroundStyle(MonitorDesktopTheme.secondaryText)
            .accessibilityHidden(true)
        }
        .padding(20)
        .background(
            MonitorDesktopTheme.cardFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(MonitorDesktopTheme.separator, lineWidth: 1)
        }
    }
}
