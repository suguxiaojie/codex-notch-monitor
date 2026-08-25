import SwiftUI

struct ActivityIslandSnapshot: Equatable {
    let projectID: String
    let projectName: String
    let phase: TaskPhase
    let actionText: String
    let sessionCount: Int
    let projectCount: Int
    let updatedAt: Date

    var fingerprint: String {
        [
            projectID,
            phase.rawValue,
            actionText,
            String(sessionCount),
            String(projectCount),
            String(updatedAt.timeIntervalSinceReferenceDate)
        ].joined(separator: "|")
    }

    func completed(at date: Date = Date()) -> ActivityIslandSnapshot {
        ActivityIslandSnapshot(
            projectID: projectID,
            projectName: projectName,
            phase: .completed,
            actionText: "本轮工作已完成",
            sessionCount: sessionCount,
            projectCount: projectCount,
            updatedAt: date
        )
    }
}

@MainActor
final class ActivityIslandViewModel: ObservableObject {
    @Published var snapshot: ActivityIslandSnapshot?
    @Published var presentation: ActivityIslandPresentation = .hidden
    @Published var reduceMotionOverride = false
    @Published var visualStyle: ActivityIslandVisualStyle = .rippleGlow
    @Published var surfaceOpacity = ActivityIslandPreferences.defaults.surfaceOpacity
    @Published var surfaceScale = CGFloat(ActivityIslandPreferences.defaults.surfaceScale)
}

struct ActivityIslandView: View {
    @ObservedObject var model: ActivityIslandViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                switch model.presentation {
                case .expanded:
                    ActivityIslandExpandedContent(
                        snapshot: snapshot,
                        style: model.visualStyle,
                        animated: !motionIsReduced
                    )
                case .compact:
                    compactContent(snapshot)
                case .hidden:
                    Color.clear
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .background(islandSurface)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.42), radius: 7, y: 2)
        .padding(ActivityIslandLayout.panelInset)
        .frame(
            width: model.presentation == .compact
                ? ActivityIslandLayout.compactSize.width
                : ActivityIslandLayout.expandedSize.width,
            height: model.presentation == .compact
                ? ActivityIslandLayout.compactSize.height
                : ActivityIslandLayout.expandedSize.height
        )
        .scaleEffect(model.surfaceScale)
        .frame(
            width: basePanelSize.width * model.surfaceScale,
            height: basePanelSize.height * model.surfaceScale
        )
        .animation(
            motionIsReduced
                ? nil
                : .easeInOut(
                    duration: model.presentation == .compact ? 0.28 : 0.30
                ),
            value: model.presentation
        )
        .animation(
            motionIsReduced ? nil : .easeInOut(duration: 0.20),
            value: model.surfaceScale
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("仅显示当前 Codex 状态")
    }

    private func compactContent(_ snapshot: ActivityIslandSnapshot) -> some View {
        HStack(spacing: 10) {
            ActivityStateOrb(
                style: model.visualStyle,
                phase: snapshot.phase,
                animated: !motionIsReduced
            )
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)

            Text(snapshot.phase.title)
                .font(AstaSans.semiBold(14))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 18)
        .frame(
            width: ActivityIslandLayout.compactSurfaceSize.width,
            height: ActivityIslandLayout.compactSurfaceSize.height
        )
    }

    private var islandSurface: some View {
        Color.black.opacity(model.surfaceOpacity)
    }

    private var basePanelSize: NSSize {
        model.presentation == .compact
            ? ActivityIslandLayout.compactSize
            : ActivityIslandLayout.expandedSize
    }

    private var cornerRadius: CGFloat {
        model.presentation == .compact
            ? ActivityIslandLayout.compactSurfaceSize.height / 2
            : 34
    }

    private var motionIsReduced: Bool {
        reduceMotion || model.reduceMotionOverride
    }

    private var accessibilityLabel: String {
        guard let snapshot = model.snapshot else { return "Codex Activity Island" }
        return "\(snapshot.projectName)，\(snapshot.phase.title)，\(snapshot.actionText)"
    }
}

struct ActivityIslandExpandedContent: View {
    let snapshot: ActivityIslandSnapshot
    let style: ActivityIslandVisualStyle
    let animated: Bool

    var body: some View {
        HStack(spacing: 2) {
            ActivityStateOrb(style: style, phase: snapshot.phase, animated: animated)
                .frame(width: 122, height: 122)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(snapshot.phase.color)
                        .frame(width: 5, height: 5)
                        .shadow(color: snapshot.phase.color.opacity(0.65), radius: 3)
                    Text(contextTitle)
                        .font(AstaSans.semiBold(11.5))
                        .foregroundStyle(.white.opacity(0.46))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }

                Text(snapshot.phase.title)
                    .font(AstaSans.semiBold(18))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(snapshot.actionText)
                    .font(AstaSans.regular(11.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 18)
        .frame(
            width: ActivityIslandLayout.expandedSurfaceSize.width,
            height: ActivityIslandLayout.expandedSurfaceSize.height
        )
    }

    private var contextTitle: String {
        var parts = [snapshot.projectName]
        if snapshot.sessionCount > 1 { parts.append("\(snapshot.sessionCount) 会话") }
        if snapshot.projectCount > 1 { parts.append("\(snapshot.projectCount) 个项目") }
        return parts.joined(separator: " · ")
    }
}

struct ActivityIslandPreview: View {
    let snapshot: ActivityIslandSnapshot
    let style: ActivityIslandVisualStyle
    let animated: Bool
    let surfaceOpacity: Double
    let surfaceScale: CGFloat

    var body: some View {
        ActivityIslandExpandedContent(snapshot: snapshot, style: style, animated: animated)
            .background {
                Color.black.opacity(surfaceOpacity)
            }
            .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.42), radius: 7, y: 2)
            .scaleEffect(surfaceScale)
            .frame(
                width: ActivityIslandLayout.expandedSurfaceSize.width * surfaceScale,
                height: ActivityIslandLayout.expandedSurfaceSize.height * surfaceScale
            )
    }
}

enum ActivityIslandLayout {
    static let panelInset: CGFloat = 10
    static let expandedSurfaceSize = NSSize(width: 424, height: 132)
    static let compactSurfaceSize = NSSize(width: 250, height: 52)
    static let expandedSize = NSSize(width: 444, height: 152)
    static let compactSize = NSSize(width: 270, height: 72)
    static let screenGap: CGFloat = 6
    static let dataPanelGap: CGFloat = 10
    static let maximumSettingsPreviewHeight: CGFloat =
        expandedSurfaceSize.height * 1.25

    static func panelSize(
        presentation: ActivityIslandPresentation,
        scale: CGFloat
    ) -> NSSize {
        let base = presentation == .compact ? compactSize : expandedSize
        return NSSize(width: base.width * scale, height: base.height * scale)
    }
}
