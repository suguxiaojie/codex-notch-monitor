import SwiftUI

enum GlanceLayout {
    static let width: CGFloat = 296
    static let height: CGFloat = 806
    static let resetPageHeight: CGFloat = 748
    static let cornerRadius: CGFloat = 26
    static let contentInset: CGFloat = 12
}

private enum GlanceActivityRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30
    case quarter = 90
    case halfYear = 180

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: return "周"
        case .month: return "月"
        case .quarter: return "三月"
        case .halfYear: return "半年"
        }
    }
}

private enum GlanceRefreshVisualState {
    case idle
    case refreshing
    case completed
}

private enum GlancePage {
    case summary
    case quotaReset
}

private struct GlanceCostBucket: Identifiable {
    let id: Int
    let label: String
    let value: Double
}

private struct GlanceTokenBucket: Identifiable {
    let id: Int
    let label: String
    let tokens: Int?
}

struct GlanceView: View {
    @ObservedObject var store: MonitorStore
    let onClose: () -> Void
    let onOpenCenter: (MonitorCenterSection) -> Void
    let onPreferredHeightChange: (CGFloat) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var activityRange: GlanceActivityRange = .week
    @State private var costRange: GlanceActivityRange = .week
    @State private var refreshVisualState: GlanceRefreshVisualState = .idle
    @State private var refreshRotation = 0.0
    @State private var refreshStartedAt = Date.distantPast
    @State private var page: GlancePage = .summary
    @State private var showsResetConfirmation = false
    @AppStorage(GlanceContentPreferenceKey.showPrimaryQuota) private var showPrimaryQuota = true
    @AppStorage(GlanceContentPreferenceKey.showSparkQuota) private var showSparkQuota = true
    @AppStorage(GlanceContentPreferenceKey.showCostEstimate) private var showCostEstimate = true
    @AppStorage(GlanceContentPreferenceKey.showCreditBalance) private var showCreditBalance = true
    @AppStorage(GlanceContentPreferenceKey.showDailyTokens) private var showDailyTokens = true
    @AppStorage(GlanceContentPreferenceKey.showThirtyDayTokens) private var showThirtyDayTokens = true
    @AppStorage(GlanceContentPreferenceKey.showTokenActivity) private var showTokenActivity = true
    @AppStorage(GlanceContentPreferenceKey.showResetEntry) private var showResetEntry = true

    var body: some View {
        Group {
            switch page {
            case .summary:
                summaryPage
            case .quotaReset:
                quotaResetPage
            }
        }
        .frame(
            width: GlanceLayout.width,
            height: preferredHeight,
            alignment: .top
        )
        .foregroundStyle(primaryText)
        .background(panelTint)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: primaryRemaining)
        .onChange(of: store.costSnapshot.updatedAt) { updatedAt in
            completeRefreshIfReady(updatedAt: updatedAt)
        }
        .onChange(of: store.costSnapshot.costActivity.count) { _ in
            completeRefreshIfReady(updatedAt: store.costSnapshot.updatedAt)
        }
        .onAppear {
            onPreferredHeightChange(preferredHeight)
        }
        .onChange(of: preferredHeight) { height in
            onPreferredHeightChange(height)
        }
        .alert("确认重置额度？", isPresented: $showsResetConfirmation) {
            Button("取消", role: .cancel) {}
            Button("消耗 1 次并重置", role: .destructive) {
                store.consumeQuotaResetCredit()
            }
        } message: {
            Text(resetConfirmationMessage)
        }
        .accessibilityElement(children: .contain)
    }

    private var summaryPage: some View {
        VStack(spacing: 0) {
            header
            currentAccountHeader

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    if showPrimaryQuota {
                        primaryQuota
                    }
                    if showSparkQuota, let supportingBucket {
                        supportingQuota(supportingBucket)
                    }
                    if showCreditBalance {
                        Divider().overlay(hairlineColor)
                        creditBalanceRow
                    }
                    if showResetEntry {
                        if showCreditBalance {
                            Divider().overlay(hairlineColor)
                        }
                        resetCreditCard(store.quotaResetCredits)
                    }
                    if showCostEstimate || showDailyTokens || showThirtyDayTokens || showTokenActivity {
                        Divider().overlay(hairlineColor)
                        currentUsageSectionHeader
                        if hasCurrentAccountHistory {
                            if showCostEstimate {
                                costEstimate
                            }
                            if showDailyTokens || showThirtyDayTokens {
                                historicalMetricsGroup
                            }
                            if showTokenActivity {
                                tokenActivity
                            }
                        } else {
                            currentAccountHistoryEmptyState
                        }
                    }
                }
                .padding(.horizontal, GlanceLayout.contentInset)
            }

            Divider().overlay(separatorColor)
            footer
                .padding(.horizontal, GlanceLayout.contentInset)
        }
    }

    private var quotaResetPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                        page = .summary
                    }
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(GlanceCircleButtonStyle())
                .help("返回额度概览")

                Text("额度重置")
                    .font(AstaSans.semiBold(15))
                    .tracking(-0.15)
                Spacer()
                Text("官方接口")
                    .font(AstaSans.semiBold(9))
                    .foregroundStyle(primaryText)
                    .padding(.horizontal, 7)
                    .frame(height: 23)
                    .background(
                        colorScheme == .dark
                            ? Color.white.opacity(0.10)
                            : Color.black.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(separatorColor, lineWidth: 0.7)
                    }
            }
            .padding(.horizontal, GlanceLayout.contentInset)
            .frame(height: 50)

            Divider().overlay(separatorColor)

            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 7) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text(store.quotaResetCredits.map { "\($0.availableCount)" } ?? "—")
                        .font(AstaSans.semiBold(34))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("可用重置次数")
                        .font(AstaSans.semiBold(10.5))
                        .foregroundStyle(secondaryText)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 10)

                VStack(spacing: 0) {
                    HStack {
                        Text("当前可用额度")
                        Spacer()
                        Text("\(primaryRemaining)%")
                            .font(AstaSans.semiBold(10.5))
                            .monospacedDigit()
                    }
                    .frame(height: 34)

                    Divider().overlay(hairlineColor)

                    HStack(spacing: 5) {
                        Image(systemName: "calendar.badge.clock")
                        Text(resetCreditExpirationText(store.quotaResetCredits))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                        Spacer(minLength: 0)
                    }
                    .frame(height: 34)
                }
                .font(AstaSans.regular(10.5))
                .foregroundStyle(secondaryText)

                VStack(alignment: .leading, spacing: 8) {
                    Label("重置前请确认", systemImage: "exclamationmark.triangle.fill")
                        .font(AstaSans.semiBold(10.5))
                        .foregroundStyle(.orange)
                    Text("• 此操作会消耗 1 次额度重置机会。")
                    Text("• 符合条件的 Codex 用量周期将立即重置。")
                    Text("• 额度重置完成后无法撤销。")
                }
                .font(AstaSans.regular(10.5))
                .foregroundStyle(secondaryText)

                Spacer(minLength: 6)

                Button {
                    showsResetConfirmation = true
                } label: {
                    HStack(spacing: 6) {
                        if store.isConsumingQuotaResetCredit {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(store.isConsumingQuotaResetCredit ? "正在重置" : "重置额度")
                    }
                    .font(AstaSans.semiBold(11))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background(
                        Color.red.opacity(canConsumeResetCredit ? 0.30 : 0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                Color.red.opacity(canConsumeResetCredit ? 0.58 : 0.22),
                                lineWidth: 0.8
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(!canConsumeResetCredit || store.isConsumingQuotaResetCredit)

                Text(store.quotaResetOperationMessage ?? resetOperationHint)
                    .font(AstaSans.regular(9))
                    .foregroundStyle(
                        store.quotaResetOperationMessage == nil
                            ? tertiaryText
                            : secondaryText
                    )
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, GlanceLayout.contentInset)
            .padding(.vertical, 12)
            .frame(maxHeight: .infinity)

            Divider().overlay(separatorColor)
            footer
                .padding(.horizontal, GlanceLayout.contentInset)
        }
    }

    private var canConsumeResetCredit: Bool {
        (store.quotaResetCredits?.availableCount ?? 0) > 0
    }

    private var contentPreferences: GlanceContentPreferences {
        GlanceContentPreferences(
            showPrimaryQuota: showPrimaryQuota,
            showSparkQuota: showSparkQuota,
            showCostEstimate: showCostEstimate,
            showCreditBalance: showCreditBalance,
            showDailyTokens: showDailyTokens,
            showThirtyDayTokens: showThirtyDayTokens,
            showTokenActivity: showTokenActivity,
            showResetEntry: showResetEntry,
            surfaceOpacity: UserDefaults.standard.object(
                forKey: GlanceContentPreferenceKey.surfaceOpacity
            ) as? Double ?? GlanceContentPreferences.defaults.surfaceOpacity
        )
    }

    private var preferredHeight: CGFloat {
        switch page {
        case .summary:
            var height = contentPreferences.preferredHeight(
                hasSupportingQuota: supportingBucket != nil
            )
            height -= 6 // Static current-account row replaces the former two-line picker.
            if !hasCurrentAccountHistory {
                if showCostEstimate { height -= 139 }
                if showDailyTokens { height -= 31 }
                if showThirtyDayTokens { height -= 31 }
                if showTokenActivity { height -= 68 }
                if showCostEstimate || showDailyTokens || showThirtyDayTokens || showTokenActivity {
                    height += 88
                }
            }
            return max(230, height)
        case .quotaReset:
            return GlanceLayout.resetPageHeight
        }
    }

    private var resetOperationHint: String {
        canConsumeResetCredit
            ? "确认后将通过官方接口消耗 1 次额度重置机会。"
            : "当前没有可用额度卡，无法执行重置。"
    }

    private var resetConfirmationMessage: String {
        "此操作将消耗 1 次额度重置机会，并立即重置符合条件的 Codex 用量周期。操作完成后无法撤销。\n\n\(resetCreditExpirationText(store.quotaResetCredits))"
    }

    private var header: some View {
        HStack(spacing: 9) {
            CodexMark(size: 23)
            Text("Codex Monitor")
                .font(AstaSans.semiBold(15))
                .tracking(-0.15)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "power")
            }
            .buttonStyle(GlancePowerButtonStyle())
            .help("收起面板")
        }
        .padding(.horizontal, GlanceLayout.contentInset)
        .frame(height: 50)
    }

    private var currentAccountHeader: some View {
        HStack(spacing: 8) {
            Text("当前账号")
                .font(AstaSans.semiBold(10.5))
                .foregroundStyle(secondaryText)
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle()
                    .fill(currentAccountIndicatorColor)
                    .frame(width: 5, height: 5)
                Text(currentAccountBadgeTitle)
                    .font(AstaSans.semiBold(9.5))
                    .lineLimit(1)
            }
            .foregroundStyle(primaryText)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                colorScheme == .dark
                    ? Color.white.opacity(0.055)
                    : Color.black.opacity(0.045),
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(separatorColor.opacity(0.75), lineWidth: 0.6)
            }
        }
        .padding(.horizontal, GlanceLayout.contentInset)
        .frame(height: 38)
    }

    private var primaryQuota: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text(primaryWindow?.windowLabel ?? "周期剩余")
                    .font(AstaSans.regular(10.5))
                    .foregroundStyle(secondaryText)
                Spacer()
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(primaryRemaining)%")
                    .font(AstaSans.semiBold(21))
                    .tracking(-0.21)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("剩余")
                    .font(AstaSans.regular(10.5))
                    .foregroundStyle(tertiaryText)
                Spacer()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(trackColor)
                    Capsule()
                        .fill(quotaColor)
                        .frame(width: proxy.size.width * CGFloat(primaryRemaining) / 100)
                }
            }
            .frame(height: 7)

            HStack(spacing: 5) {
                Image(systemName: "clock")
                    .font(.system(size: 8, weight: .semibold))
                Text(resetText(primaryWindow))
                Spacer()
                Text(primaryWindow.map { "已使用 \($0.usedPercent)%" } ?? "额度未知")
            }
            .font(AstaSans.regular(10.5))
            .foregroundStyle(tertiaryText)
        }
        .padding(.vertical, 9)
    }

    private func supportingQuota(_ bucket: RateLimitBucket) -> some View {
        VStack(spacing: 9) {
            if let window = bucket.headlineWindow {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(supportingQuotaTitle(bucket))
                        .font(AstaSans.regular(10.5))
                        .foregroundStyle(secondaryText)
                    Text("\(window.remainingPercent)%")
                        .font(AstaSans.semiBold(10.5))
                        .foregroundStyle(primaryText)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                    Spacer(minLength: 6)
                }

                GeometryReader { proxy in
                    let progress = CGFloat(window.remainingPercent) / 100
                    ZStack(alignment: .leading) {
                        Capsule().fill(trackColor)
                        Capsule()
                            .fill(neutralQuotaColor)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 7)

                HStack(spacing: 6) {
                    Text("下次重置 \(compactResetDuration(window))")
                        .contentTransition(.numericText())
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("已使用 \(window.usedPercent)%")
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
                .font(AstaSans.regular(10.5))
                .foregroundStyle(secondaryText)
            }
        }
        .padding(.vertical, 7)
    }

    private func supportingQuotaTitle(_ bucket: RateLimitBucket) -> String {
        bucket.name.localizedCaseInsensitiveContains("spark")
            ? "Spark 周额度"
            : "\(bucket.name) 额度"
    }

    private func compactResetDuration(_ window: RateLimitWindow) -> String {
        guard let resetAt = window.resetsAt else { return "未知" }
        let totalMinutes = max(0, Int(resetAt.timeIntervalSinceNow / 60))
        let totalHours = totalMinutes / 60
        if totalHours >= 24 {
            let days = totalHours / 24
            let hours = totalHours % 24
            return hours > 0 ? "\(days)天 \(hours)小时" : "\(days)天"
        }
        if totalHours > 0 {
            let minutes = totalMinutes % 60
            return minutes > 0 ? "\(totalHours)小时 \(minutes)分" : "\(totalHours)小时"
        }
        return "\(max(1, totalMinutes))分"
    }

    private var metrics: some View {
        VStack(spacing: 0) {
            if showDailyTokens {
                metricRow(
                    title: "今日 Token",
                    value: compactTokens(selectedCostScope.usage.day.tokens),
                    color: primaryText
                )
            }
            if showDailyTokens && showThirtyDayTokens {
                Divider().overlay(hairlineColor)
            }
            if showThirtyDayTokens {
                metricRow(
                    title: "30 日 Token",
                    value: compactTokens(selectedCostScope.usage.month.tokens),
                    color: primaryText
                )
            }
        }
        .padding(.vertical, 2)
    }

    private var numericMetricsGroup: some View {
        VStack(spacing: 0) {
            Divider().overlay(hairlineColor)
            if showCreditBalance {
                creditBalanceRow
            }
            if showCreditBalance && (showDailyTokens || showThirtyDayTokens) {
                Divider().overlay(hairlineColor)
            }
            if showDailyTokens || showThirtyDayTokens {
                metrics
            }
            Divider().overlay(hairlineColor)
        }
    }

    private var currentUsageSectionHeader: some View {
        HStack {
            Text("当前账号用量")
                .font(AstaSans.semiBold(10.5))
                .foregroundStyle(secondaryText)
            Spacer()
            if let currentAccount {
                Text(currentAccount.alias)
                    .font(AstaSans.regular(9))
                    .foregroundStyle(tertiaryText)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    private var historicalMetricsGroup: some View {
        VStack(spacing: 0) {
            if showDailyTokens {
                metricRow(
                    title: "今日 Token",
                    value: compactTokens(selectedCostScope.usage.day.tokens),
                    color: primaryText
                )
            }
            if showDailyTokens && showThirtyDayTokens {
                Divider().overlay(hairlineColor)
            }
            if showThirtyDayTokens {
                metricRow(
                    title: "30 日 Token",
                    value: compactTokens(selectedCostScope.usage.month.tokens),
                    color: primaryText
                )
            }
            Divider().overlay(hairlineColor)
        }
        .padding(.vertical, 2)
    }

    private var currentAccountHistoryEmptyState: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Image(systemName: "tray")
                    .foregroundStyle(secondaryText)
                Text("当前账号暂无本地用量记录")
                    .font(AstaSans.semiBold(10.5))
                    .foregroundStyle(primaryText)
            }
            Text("尚未识别到归属该账号的 Cost 或 Token 数据。")
                .font(AstaSans.regular(9))
                .foregroundStyle(tertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .background(
            colorScheme == .dark
                ? Color.white.opacity(0.025)
                : Color.black.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(.vertical, 8)
    }

    private var creditBalanceRow: some View {
        HStack {
            Text("Credits 余额")
                .font(AstaSans.semiBold(10.5))
                .foregroundStyle(secondaryText)
            Spacer()
            Text(primaryBucket?.creditBalance ?? "—")
                .font(AstaSans.regular(10.5))
                .foregroundStyle(primaryText)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(height: 29)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Credits 余额")
        .accessibilityValue(primaryBucket?.creditBalance ?? "数据未知")
    }

    private var costEstimate: some View {
        let activity = Array(selectedCostScope.costActivity.suffix(costRange.rawValue))
        let buckets = costChartBuckets(activity, range: costRange)
        let total = activity.reduce(0) { $0 + $1.dollars }
        let maximum = activity.map(\.dollars).max() ?? 0
        let latest = activity.last(where: { $0.dollars > 0 })?.dollars ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("成本估算（\(costRange.rawValue) 天）")
                    .font(AstaSans.regular(10.5))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 2) {
                    ForEach(GlanceActivityRange.allCases) { range in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                costRange = range
                            }
                        } label: {
                            Text(range.title)
                                .font(
                                    costRange == range
                                        ? AstaSans.semiBold(9)
                                        : AstaSans.regular(9)
                                )
                                .foregroundStyle(
                                    costRange == range
                                        ? primaryText
                                        : tertiaryText
                                )
                                .padding(.horizontal, 3)
                                .frame(height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看近 \(range.rawValue) 天成本估算")
                    }
                }
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(detailedDollars(total))
                    .font(AstaSans.semiBold(21))
                    .tracking(-0.21)
                    .foregroundStyle(primaryText)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                Text("峰值 \(detailedDollars(maximum))")
                    .font(AstaSans.regular(9))
                    .foregroundStyle(secondaryText)
                    .monospacedDigit()
            }

            CostMiniBarChart(buckets: buckets)
                .frame(height: 42)
                .padding(.horizontal, 4)

            HStack {
                Text("估算值 · 非账单")
                Spacer()
                Text("最近一天 \(detailedDollars(latest))")
                    .monospacedDigit()
            }
            .font(AstaSans.regular(10.5))
            .foregroundStyle(secondaryText)
        }
        .padding(.top, 6)
        .padding(.bottom, 7)
    }

    private func costChartBuckets(
        _ activity: [DailyCostActivity],
        range: GlanceActivityRange
    ) -> [GlanceCostBucket] {
        guard !activity.isEmpty else {
            let count = CostActivityBucketLayout.ranges(
                dayCount: range.rawValue,
                rangeDays: range.rawValue
            ).count
            return (0..<count).map {
                GlanceCostBucket(id: $0, label: "无数据", value: 0)
            }
        }
        return CostActivityBucketLayout.ranges(
            dayCount: activity.count,
            rangeDays: range.rawValue
        ).enumerated().map { index, bucketRange in
            let slice = activity[bucketRange]
            let startDate = slice.first?.date ?? Date()
            let endDate = slice.last?.date ?? startDate
            return GlanceCostBucket(
                id: index,
                label: dateRangeLabel(from: startDate, to: endDate),
                value: slice.reduce(0) { $0 + $1.dollars }
            )
        }
    }

    private func dateRangeLabel(from start: Date, to end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: end)
        return startText == endText ? startText : "\(startText)–\(endText)"
    }

    private func detailedDollars(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "$%.2f", value)
    }

    private func metricRow(title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
                .font(AstaSans.semiBold(10.5))
                .foregroundStyle(secondaryText)
            Spacer()
            Text(value)
                .font(AstaSans.regular(10.5))
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(height: 29)
    }

    private var tokenActivity: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Token 活动")
                    .font(AstaSans.semiBold(10.5))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(GlanceActivityRange.allCases) { range in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                                activityRange = range
                            }
                        } label: {
                            Text(range.title)
                                .font(
                                    activityRange == range
                                        ? AstaSans.semiBold(9)
                                        : AstaSans.regular(9)
                                )
                                .foregroundStyle(
                                    activityRange == range
                                        ? primaryText
                                        : tertiaryText
                                )
                                .padding(.horizontal, 4)
                                .frame(height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看近 \(range.rawValue) 日 Token 活动")
                    }
                }
            }

            TokenActivityMiniGrid(
                activity: selectedCostScope.usage.activity,
                rangeDays: activityRange.rawValue
            )
            .id(activityRange)
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerUpdateText)
                .font(AstaSans.regular(10.5))
                .foregroundStyle(secondaryText)
            Circle()
                .fill(footerStatusColor)
                .frame(width: 5, height: 5)
            Spacer()
            refreshFooterButton
            footerButton(symbol: "bolt.horizontal.circle", help: "打开动态中心") {
                onOpenCenter(.tibo)
            }
            footerButton(symbol: "gearshape", help: "打开 Usage") {
                onOpenCenter(.usage)
            }
        }
        .frame(height: 48)
    }

    private func resetCreditCard(_ summary: QuotaResetCreditSummary?) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                page = .quotaReset
            }
        } label: {
            resetCreditCardContent(summary)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "额度重置，\(summary.map { "\($0.availableCount) 次可用" } ?? "可用次数未知")，\(resetCreditExpirationText(summary))"
        )
        .accessibilityHint("打开额度重置确认页面")
    }

    private func resetCreditCardContent(
        _ summary: QuotaResetCreditSummary?
    ) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text("额度重置")
                    .font(AstaSans.semiBold(10.5))
                    .foregroundStyle(primaryText)
                HStack(spacing: 5) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(resetCreditExpirationText(summary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.84)
                }
                .font(AstaSans.regular(9))
                .foregroundStyle(secondaryText)
            }
            Spacer(minLength: 4)
            resetCreditBadge(summary)
            Image(systemName: "chevron.right")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(secondaryText)
        }
        .frame(height: 54)
        .contentShape(Rectangle())
    }

    private func resetCreditBadge(
        _ summary: QuotaResetCreditSummary?
    ) -> some View {
        Text(summary.map { "\($0.availableCount)次可用" } ?? "数据未知")
            .font(AstaSans.semiBold(9))
            .foregroundStyle(resetBadgeText)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                resetBadgeFill,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(resetBadgeBorder, lineWidth: 0.7)
            }
            .monospacedDigit()
    }

    private var resetBadgeText: Color {
        colorScheme == .dark ? Color.white.opacity(0.88) : Color.black.opacity(0.82)
    }

    private var resetBadgeFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.055)
    }

    private var resetBadgeBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
    }

    private func resetCreditExpirationText(_ summary: QuotaResetCreditSummary?) -> String {
        let now = Date()
        guard let expiration = summary?.nearestExpiration(relativeTo: now) else {
            return "有效期未知"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d HH:mm"
        let value = formatter.string(from: expiration)
        return expiration > now
            ? "有效期至 \(value)"
            : "已于 \(value) 过期"
    }

    private func footerButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(GlanceCircleButtonStyle())
        .help(help)
    }

    private var refreshFooterButton: some View {
        Button(action: beginManualRefresh) {
            Image(
                systemName: refreshVisualState == .completed
                    ? "checkmark"
                    : "arrow.clockwise"
            )
            .rotationEffect(
                .degrees(refreshVisualState == .refreshing ? refreshRotation : 0)
            )
            .scaleEffect(refreshVisualState == .completed ? 1.08 : 1)
        }
        .buttonStyle(GlanceCircleButtonStyle())
        .disabled(refreshVisualState == .refreshing)
        .help(
            refreshVisualState == .refreshing
                ? "正在刷新"
                : (refreshVisualState == .completed ? "刷新完成" : "刷新全部数据")
        )
        .accessibilityLabel(
            refreshVisualState == .refreshing
                ? "正在刷新"
                : (refreshVisualState == .completed ? "刷新完成" : "刷新全部数据")
        )
    }

    private func beginManualRefresh() {
        guard refreshVisualState != .refreshing else { return }
        refreshStartedAt = Date()
        refreshVisualState = .refreshing
        refreshRotation = 0
        if !reduceMotion {
            withAnimation(.linear(duration: 0.72).repeatForever(autoreverses: false)) {
                refreshRotation = 360
            }
        }
        store.refreshAll()

        let startedAt = refreshStartedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            guard refreshVisualState == .refreshing,
                  refreshStartedAt == startedAt
            else { return }
            finishManualRefresh()
        }
    }

    private func completeRefreshIfReady(updatedAt: Date) {
        guard refreshVisualState == .refreshing,
              updatedAt >= refreshStartedAt,
              !store.costSnapshot.costActivity.isEmpty
        else { return }
        finishManualRefresh()
    }

    private func finishManualRefresh() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72)) {
            refreshRotation = 0
            refreshVisualState = .completed
        }
        let completedAt = refreshStartedAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard refreshVisualState == .completed,
                  refreshStartedAt == completedAt
            else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                refreshVisualState = .idle
            }
        }
    }

    private var primaryBucket: RateLimitBucket? {
        store.quotaState.primaryBucket
    }

    private var currentAccount: UsageAccountOption? {
        guard let id = UsageAccountSelection.currentAccountID(
            in: store.usageAccountOptions
        ) else { return nil }
        return store.usageAccountOptions.first { $0.id == id }
    }

    private var selectedCostScope: CostScopeSnapshot {
        guard let currentAccount else { return .empty }
        return store.costSnapshot.scope(for: currentAccount.id)
    }

    private var currentAccountBadgeTitle: String {
        let alias = currentAccount?.alias ?? store.continuityAccountTitle
        let plan = OpenAIPlanDisplayName.resolve(primaryBucket?.planType)
        return [alias, plan].compactMap { $0 }.joined(separator: " · ")
    }

    private var primaryWindow: RateLimitWindow? {
        primaryBucket?.headlineWindow
    }

    private var currentAccountIndicatorColor: Color {
        switch store.quotaState {
        case .loaded: return Color.green.opacity(0.90)
        case .loading: return Color.cyan.opacity(0.82)
        case .failed: return Color.orange.opacity(0.88)
        }
    }

    private var hasCurrentAccountHistory: Bool {
        selectedCostScope.month.tokens > 0
            || selectedCostScope.month.dollars > 0
            || selectedCostScope.usage.month.sessionCount > 0
    }

    private var primaryRemaining: Int {
        primaryWindow?.remainingPercent ?? 0
    }

    private var supportingBucket: RateLimitBucket? {
        guard let primaryID = primaryBucket?.id else { return store.quotaState.buckets.dropFirst().first }
        return store.quotaState.buckets.first { $0.id != primaryID }
    }

    private var quotaColor: Color {
        if primaryRemaining < 20 { return .red }
        if primaryRemaining < 50 { return .orange }
        return Color(red: 0.35, green: 0.93, blue: 0.38)
    }

    private var footerUpdateText: String {
        switch store.quotaState {
        case .loading:
            return "正在更新"
        case let .loaded(_, date):
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return "更新于 \(formatter.string(from: date))"
        case .failed:
            return "数据可能过期"
        }
    }

    private var footerStatusColor: Color {
        switch store.quotaState {
        case .loaded: return .green
        case .loading: return .orange
        case .failed: return .red
        }
    }

    private func resetText(_ window: RateLimitWindow?) -> String {
        guard let date = window?.resetsAt else { return "重置时间未知" }
        return QuotaResetCountdown.text(until: date, relativeTo: Date())
    }

    private func compactTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 { return String(format: "%.1fB", Double(value) / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private var primaryText: Color {
        colorScheme == .dark ? .white.opacity(0.98) : .black.opacity(0.92)
    }

    private var secondaryText: Color {
        colorScheme == .dark ? .white.opacity(0.82) : .black.opacity(0.74)
    }

    private var tertiaryText: Color {
        colorScheme == .dark ? .white.opacity(0.66) : .black.opacity(0.58)
    }

    private var separatorColor: Color {
        colorScheme == .dark ? .white.opacity(0.09) : .black.opacity(0.10)
    }

    private var hairlineColor: Color {
        colorScheme == .dark ? .white.opacity(0.065) : .black.opacity(0.075)
    }

    private var trackColor: Color {
        colorScheme == .dark ? .white.opacity(0.13) : .black.opacity(0.12)
    }

    private var neutralQuotaColor: Color {
        colorScheme == .dark ? .white.opacity(0.66) : .black.opacity(0.70)
    }

    private var panelTint: Color {
        .clear
    }
}

private struct CostMiniBarChart: View {
    let buckets: [GlanceCostBucket]
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredBucketID: Int?

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let bucket = hoveredBucket {
                    Text("\(bucket.label) · \(exactDollars(bucket.value))")
                        .foregroundStyle(tooltipTextColor)
                        .padding(.horizontal, 7)
                        .background(tooltipBackground, in: Capsule())
                } else {
                    Color.clear
                }
            }
            .font(AstaSans.regular(9))
            .frame(height: 16)

            GeometryReader { proxy in
                let maximum = max(buckets.map(\.value).max() ?? 0, 0.000_001)
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(buckets) { bucket in
                        ZStack(alignment: .bottom) {
                            if bucket.value > 0 {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(
                                        barColor(
                                            value: bucket.value,
                                            maximum: maximum,
                                            hovered: hoveredBucketID == bucket.id
                                        )
                                    )
                                    .frame(
                                        height: max(
                                            4,
                                            proxy.size.height * CGFloat(bucket.value / maximum)
                                        )
                                    )
                            }

                            Color.clear
                                .contentShape(Rectangle())
                        }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                hoveredBucketID = hovering ? bucket.id : nil
                            }
                            .accessibilityLabel(
                                "\(bucket.label)，成本估算 \(exactDollars(bucket.value))"
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
        .accessibilityLabel("30 天成本估算柱状图")
    }

    private var hoveredBucket: GlanceCostBucket? {
        buckets.first(where: { $0.id == hoveredBucketID })
    }

    private func exactDollars(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.currencySymbol = "US$"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "US$%.2f", value)
    }

    private func barColor(
        value: Double,
        maximum: Double,
        hovered: Bool
    ) -> Color {
        let level = CostActivityScale.level(dollars: value, maximum: maximum)
        let baseOpacity: Double
        switch level {
        case 1: baseOpacity = 0.26
        case 2: baseOpacity = 0.42
        case 3: baseOpacity = 0.60
        case 4: baseOpacity = 0.82
        default: return .clear
        }
        let opacity = min(1, baseOpacity + (hovered ? 0.14 : 0))
        return colorScheme == .dark
            ? .white.opacity(opacity)
            : .black.opacity(opacity)
    }

    private var tooltipBackground: Color {
        colorScheme == .dark ? .white.opacity(0.90) : .black.opacity(0.82)
    }

    private var tooltipTextColor: Color {
        colorScheme == .dark ? .black.opacity(0.88) : .white.opacity(0.94)
    }
}

private struct TokenActivityMiniGrid: View {
    let activity: [DailyTokenActivity]
    let rangeDays: Int
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredBucketID: Int?
    @State private var hoverClearWorkItem: DispatchWorkItem?

    private let columns = Array(
        repeating: GridItem(.fixed(12), spacing: 3),
        count: 16
    )

    var body: some View {
        VStack(spacing: 2) {
            Group {
                if let bucket = hoveredBucket, let tokens = bucket.tokens {
                    Text("\(bucket.label) · \(exactTokens(tokens)) Tokens")
                        .font(AstaSans.regular(9))
                        .foregroundStyle(tooltipTextColor)
                        .padding(.horizontal, 7)
                        .background(tooltipBackground, in: Capsule())
                        .transition(.opacity)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, minHeight: 14, maxHeight: 14, alignment: .trailing)
            .allowsHitTesting(false)

            LazyVGrid(columns: columns, alignment: .center, spacing: 3) {
                ForEach(buckets) { bucket in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(cellColor(bucket.tokens ?? 0))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .strokeBorder(
                                    bucket.tokens == nil ? placeholderBorder : .clear,
                                    style: StrokeStyle(lineWidth: 0.6, dash: [2, 2])
                                )
                        }
                        .contentShape(Rectangle())
                        .onHover { hovering in
                            updateHover(bucketID: bucket.id, hovering: hovering)
                        }
                        .accessibilityLabel(
                            bucket.tokens.map {
                                "\(bucket.label)，\(exactTokens($0)) Tokens"
                            } ?? "无数据"
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onDisappear {
            hoverClearWorkItem?.cancel()
            hoverClearWorkItem = nil
            hoveredBucketID = nil
        }
    }

    private var buckets: [GlanceTokenBucket] {
        let recent = Array(activity.suffix(rangeDays))
        guard !recent.isEmpty else {
            return (0..<16).map {
                GlanceTokenBucket(id: $0, label: "无数据", tokens: nil)
            }
        }

        if recent.count <= 16 {
            let placeholderCount = 16 - recent.count
            let placeholders = (0..<placeholderCount).map {
                GlanceTokenBucket(id: $0, label: "无数据", tokens: nil)
            }
            let values = recent.enumerated().map { index, day in
                GlanceTokenBucket(
                    id: placeholderCount + index,
                    label: shortDate(day.date),
                    tokens: day.tokens
                )
            }
            return placeholders + values
        }

        return (0..<16).map { index in
            let start = Int(Double(index) * Double(recent.count) / 16)
            let end = max(
                start + 1,
                Int(Double(index + 1) * Double(recent.count) / 16)
            )
            let boundedEnd = min(end, recent.count)
            let slice = recent[start..<boundedEnd]
            let startDate = slice.first?.date ?? Date()
            let endDate = slice.last?.date ?? startDate
            return GlanceTokenBucket(
                id: index,
                label: dateRangeLabel(from: startDate, to: endDate),
                tokens: slice.reduce(0) { $0 + $1.tokens }
            )
        }
    }

    private var maximum: Int {
        max(1, buckets.compactMap(\.tokens).max() ?? 1)
    }

    private func cellColor(_ tokens: Int) -> Color {
        guard tokens > 0 else {
            return colorScheme == .dark
                ? Color.white.opacity(0.055)
                : Color.black.opacity(0.055)
        }
        let ratio = Double(tokens) / Double(maximum)
        let opacity = 0.18 + min(0.62, ratio * 0.62)
        return colorScheme == .dark
            ? Color.white.opacity(opacity)
            : Color.black.opacity(opacity)
    }

    private var placeholderBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.22)
            : Color.black.opacity(0.22)
    }

    private var hoveredBucket: GlanceTokenBucket? {
        buckets.first(where: { $0.id == hoveredBucketID })
    }

    private func updateHover(bucketID: Int, hovering: Bool) {
        hoverClearWorkItem?.cancel()
        hoverClearWorkItem = nil
        if hovering {
            hoveredBucketID = bucketID
            return
        }
        let work = DispatchWorkItem {
            guard hoveredBucketID == bucketID else { return }
            hoveredBucketID = nil
        }
        hoverClearWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }

    private func dateRangeLabel(from start: Date, to end: Date) -> String {
        let startText = shortDate(start)
        let endText = shortDate(end)
        return startText == endText ? startText : "\(startText)–\(endText)"
    }

    private func exactTokens(_ value: Int) -> String {
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", Double(value) / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private var tooltipBackground: Color {
        colorScheme == .dark ? .white.opacity(0.90) : .black.opacity(0.82)
    }

    private var tooltipTextColor: Color {
        colorScheme == .dark ? .black.opacity(0.88) : .white.opacity(0.94)
    }

}

private struct GlanceCircleButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(
                colorScheme == .dark
                    ? Color.white.opacity(configuration.isPressed ? 0.92 : 0.60)
                    : Color.black.opacity(configuration.isPressed ? 0.82 : 0.56)
            )
            .frame(width: 28, height: 28)
            .background(
                colorScheme == .dark
                    ? Color.white.opacity(configuration.isPressed ? 0.11 : 0.055)
                    : Color.black.opacity(configuration.isPressed ? 0.10 : 0.050),
                in: Circle()
            )
            .contentShape(Circle())
    }
}

private struct GlancePowerButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(
                colorScheme == .dark
                    ? Color.white.opacity(configuration.isPressed ? 1 : 0.94)
                    : Color.black.opacity(configuration.isPressed ? 0.96 : 0.88)
            )
            .frame(width: 28, height: 28)
            .background(
                colorScheme == .dark
                    ? Color.white.opacity(configuration.isPressed ? 0.09 : 0.025)
                    : Color.black.opacity(configuration.isPressed ? 0.08 : 0.018),
                in: Circle()
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(configuration.isPressed ? 0.34 : 0.22)
                            : Color.black.opacity(configuration.isPressed ? 0.28 : 0.18),
                        lineWidth: 0.8
                    )
            }
            .contentShape(Circle())
    }
}
