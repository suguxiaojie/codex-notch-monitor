import Foundation

enum ActivityIslandPresentation: Equatable {
    case hidden
    case expanded
    case compact
}

enum ActivityIslandLifecycleEvent: Equatable {
    case activityChanged(requiresAttention: Bool)
    case activityEnded
    case expandedHoldElapsed
    case compactHideElapsed
}

/// Pure state transitions for the floating activity island. AppKit owns the
/// timers; this type keeps stale timer callbacks and attention states from
/// accidentally hiding an approval or error that still needs the user.
struct ActivityIslandLifecycle: Equatable {
    private(set) var presentation: ActivityIslandPresentation = .hidden
    private(set) var requiresAttention = false
    private(set) var hidesAfterCompact = false

    mutating func handle(_ event: ActivityIslandLifecycleEvent) -> ActivityIslandPresentation {
        switch event {
        case let .activityChanged(attention):
            requiresAttention = attention
            hidesAfterCompact = false
            presentation = .expanded

        case .activityEnded:
            requiresAttention = false
            hidesAfterCompact = true
            presentation = .expanded

        case .expandedHoldElapsed:
            if !requiresAttention, presentation == .expanded {
                presentation = .compact
            }

        case .compactHideElapsed:
            if !requiresAttention, hidesAfterCompact, presentation == .compact {
                presentation = .hidden
            }
        }
        return presentation
    }
}

enum ActivityIslandTiming {
    static let liveExpandedHold: TimeInterval = 5
}
