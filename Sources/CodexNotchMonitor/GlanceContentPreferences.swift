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

    func preferredHeight(hasSupportingQuota: Bool) -> CGFloat {
        var height: CGFloat = 161
        if showPrimaryQuota { height += 94 }
        if showSparkQuota && hasSupportingQuota { height += 68 }
        if showCostEstimate { height += 139 }
        if showCreditBalance { height += 31 }
        if showDailyTokens { height += 31 }
        if showThirtyDayTokens { height += 31 }
        if showTokenActivity { height += 68 }
        if showResetEntry { height += 55 }
        return min(GlanceLayout.height, max(230, height))
    }
}

struct GlanceContentSettingsView: View {
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

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 14) {
                settingsGroup(title: "额度") {
                    contentRow(
                        title: "周期用量概览",
                        detail: "显示当前周期的已用量、剩余量和重置时间。",
                        isOn: $showPrimaryQuota
                    )
                    divider
                    contentRow(
                        title: "Spark 周额度",
                        detail: "有可用数据时，在周期额度下方显示 Spark 周额度。",
                        isOn: $showSparkQuota
                    )
                    divider
                    contentRow(
                        title: "Credits 余额",
                        detail: "显示当前登录账号由 App Server 返回的 Credits 余额。",
                        isOn: $showCreditBalance
                    )
                    divider
                    contentRow(
                        title: "额度重置入口",
                        detail: "显示额度卡次数、到期时间和真实重置入口。",
                        isOn: $showResetEntry
                    )
                }

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
                        detail: "显示 Token 活动，并支持周、月、三月和半年。",
                        isOn: $showTokenActivity
                    )
                }

                settingsGroup(title: "成本") {
                    contentRow(
                        title: "成本估算图表",
                        detail: "显示可切换周、月、三月和半年的成本估算。",
                        isOn: $showCostEstimate
                    )
                }

                opacityCard
            }
        }
        .scrollDisabled(isAdjustingOpacity)
        .onDisappear { isAdjustingOpacity = false }
        .onChange(of: surfaceOpacity) { opacity in
            NotificationCenter.default.post(
                name: .glanceSurfaceOpacityDidChange,
                object: opacity
            )
        }
    }

    private func settingsGroup<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(MonitorTypography.metadataMedium)
                .foregroundStyle(MonitorTheme.secondaryText)
                .padding(.top, 12)
                .padding(.bottom, 8)
            divider
            content()
        }
        .padding(.horizontal, 18)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 0.7)
        }
    }

    private func contentRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 18) {
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
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: MonitorTheme.selection))
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue(isOn.wrappedValue ? "显示" : "隐藏")
        }
        .padding(.vertical, 10)
        .frame(minHeight: MonitorGeometry.settingsRowHeight)
    }

    private var divider: some View {
        Divider().overlay(MonitorTheme.separator)
    }

    private var opacityCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("面板透明度")
                        .font(MonitorTypography.cardTitle)
                    Text("数值越低越透明；只调整黑色背景，不增加磨砂。")
                        .font(MonitorTypography.body)
                        .foregroundStyle(MonitorTheme.tertiaryText)
                }
                Spacer()
                Text("\(Int((surfaceOpacity * 100).rounded()))%")
                    .font(MonitorTypography.rowTitle)
                    .monospacedDigit()
            }
            Slider(
                value: $surfaceOpacity,
                in: 0.10...0.90,
                step: 0.01,
                onEditingChanged: { isAdjustingOpacity = $0 }
            )
            .tint(MonitorTheme.selection)
            .accessibilityLabel("面板透明度")
            .accessibilityValue("\(Int((surfaceOpacity * 100).rounded()))%")
        }
        .padding(16)
        .background(
            MonitorTheme.cardFill,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.055), lineWidth: 0.7)
        }
    }
}
