import Foundation
import simd

struct RippleGlowStyle: Equatable {
    let primary: SIMD4<Float>
    let secondary: SIMD4<Float>
    let accent: SIMD4<Float>
    let highlight: SIMD4<Float>
    let speed: Float
    let warp: Float
    let ridgeAmount: Float
    let sharpness: Float
    let exposure: Float

    static func mix(
        _ current: RippleGlowStyle,
        toward target: RippleGlowStyle,
        factor: Float
    ) -> RippleGlowStyle {
        let amount = max(0, min(1, factor))
        if amount == 0 { return current }
        if amount == 1 { return target }
        return RippleGlowStyle(
            primary: simd_mix(current.primary, target.primary, SIMD4<Float>(repeating: amount)),
            secondary: simd_mix(current.secondary, target.secondary, SIMD4<Float>(repeating: amount)),
            accent: simd_mix(current.accent, target.accent, SIMD4<Float>(repeating: amount)),
            highlight: simd_mix(current.highlight, target.highlight, SIMD4<Float>(repeating: amount)),
            speed: current.speed + (target.speed - current.speed) * amount,
            warp: current.warp + (target.warp - current.warp) * amount,
            ridgeAmount: current.ridgeAmount + (target.ridgeAmount - current.ridgeAmount) * amount,
            sharpness: current.sharpness + (target.sharpness - current.sharpness) * amount,
            exposure: current.exposure + (target.exposure - current.exposure) * amount
        )
    }
}

enum RippleGlowStyles {
    static func style(for phase: TaskPhase?) -> RippleGlowStyle {
        switch phase {
        case .starting:
            return style(
                primary: (0.12, 0.23, 0.42),
                secondary: (0.25, 0.35, 0.58),
                accent: (0.44, 0.56, 0.75),
                highlight: (0.90, 0.94, 1.00),
                speed: 0.48,
                warp: 1.9,
                ridgeAmount: 0.28,
                sharpness: 1.8,
                exposure: 1.55
            )
        case .working:
            return style(
                primary: (0.20, 0.12, 0.68),
                secondary: (0.50, 0.23, 0.88),
                accent: (0.34, 0.57, 1.00),
                highlight: (0.96, 0.91, 1.00),
                speed: 1.23,
                warp: 3.2,
                ridgeAmount: 0.50,
                sharpness: 2.2,
                exposure: 2.00
            )
        case .usingTool:
            return style(
                primary: (0.04, 0.30, 0.78),
                secondary: (0.02, 0.65, 0.90),
                accent: (0.28, 0.94, 0.84),
                highlight: (0.92, 1.00, 1.00),
                speed: 1.72,
                warp: 3.8,
                ridgeAmount: 0.68,
                sharpness: 2.5,
                exposure: 2.05
            )
        case .waitingApproval:
            return style(
                primary: (0.55, 0.21, 0.02),
                secondary: (0.95, 0.46, 0.05),
                accent: (1.00, 0.78, 0.22),
                highlight: (1.00, 0.94, 0.72),
                speed: 0.72,
                warp: 2.3,
                ridgeAmount: 0.38,
                sharpness: 2.0,
                exposure: 1.86
            )
        case .completed:
            return style(
                primary: (0.02, 0.38, 0.22),
                secondary: (0.05, 0.70, 0.40),
                accent: (0.36, 0.95, 0.65),
                highlight: (0.90, 1.00, 0.95),
                speed: 0.54,
                warp: 1.8,
                ridgeAmount: 0.30,
                sharpness: 1.8,
                exposure: 1.70
            )
        case .failed:
            return style(
                primary: (0.55, 0.01, 0.05),
                secondary: (0.92, 0.08, 0.14),
                accent: (1.00, 0.36, 0.22),
                highlight: (1.00, 0.88, 0.82),
                speed: 1.44,
                warp: 3.9,
                ridgeAmount: 0.74,
                sharpness: 2.8,
                exposure: 1.98
            )
        case .ended:
            return style(
                primary: (0.23, 0.25, 0.30),
                secondary: (0.36, 0.38, 0.43),
                accent: (0.50, 0.53, 0.58),
                highlight: (0.78, 0.80, 0.84),
                speed: 0.12,
                warp: 0.8,
                ridgeAmount: 0.08,
                sharpness: 1.4,
                exposure: 1.20
            )
        case nil:
            return style(
                primary: (0.13, 0.17, 0.24),
                secondary: (0.28, 0.34, 0.44),
                accent: (0.48, 0.57, 0.70),
                highlight: (0.86, 0.90, 0.96),
                speed: 0.18,
                warp: 1.6,
                ridgeAmount: 0.22,
                sharpness: 1.7,
                exposure: 1.45
            )
        }
    }

    private static func style(
        primary: (Float, Float, Float),
        secondary: (Float, Float, Float),
        accent: (Float, Float, Float),
        highlight: (Float, Float, Float),
        speed: Float,
        warp: Float,
        ridgeAmount: Float,
        sharpness: Float,
        exposure: Float
    ) -> RippleGlowStyle {
        RippleGlowStyle(
            primary: SIMD4(primary.0, primary.1, primary.2, 1),
            secondary: SIMD4(secondary.0, secondary.1, secondary.2, 1),
            accent: SIMD4(accent.0, accent.1, accent.2, 1),
            highlight: SIMD4(highlight.0, highlight.1, highlight.2, 1),
            speed: speed,
            warp: warp,
            ridgeAmount: ridgeAmount,
            sharpness: sharpness,
            exposure: exposure
        )
    }
}
