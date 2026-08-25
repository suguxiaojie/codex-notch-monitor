import SwiftUI

struct ActivityStateOrb: View {
    let style: ActivityIslandVisualStyle
    let phase: TaskPhase?
    let animated: Bool

    var body: some View {
        switch style {
        case .rippleGlow:
            RippleGlowOrb(phase: phase, animated: animated)
        case .particleOrb:
            ParticleOrb(phase: phase, animated: animated)
        }
    }
}

struct ParticleOrb: NSViewRepresentable {
    let phase: TaskPhase?
    let animated: Bool

    func makeNSView(context: Context) -> ParticleOrbHostView {
        ParticleOrbHostView(phase: phase, animated: animated)
    }

    func updateNSView(_ view: ParticleOrbHostView, context: Context) {
        view.update(phase: phase, animated: animated)
    }
}
