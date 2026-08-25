import Foundation

@main
enum RippleGlowRuntimeTests {
    static func main() {
        if let error = RippleGlowRuntimeValidator.validationError() {
            fputs("Ripple Glow runtime test failed: \(error)\n", stderr)
            exit(1)
        }
        if let error = ParticleOrbRuntimeValidator.validationError() {
            fputs("Particle Orb runtime test failed: \(error)\n", stderr)
            exit(1)
        }
        print("QuotaView orb runtime test passed: Ripple Glow and Particle Orb Metal pipelines are available.")
    }
}
