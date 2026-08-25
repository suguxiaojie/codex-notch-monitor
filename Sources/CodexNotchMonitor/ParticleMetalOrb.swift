import AppKit
import MetalKit
import QuartzCore
import simd
import SwiftUI

private struct ParticleOrbStyle {
    var primary: SIMD4<Float>
    var secondary: SIMD4<Float>
    var accent: SIMD4<Float>
    var speed: Float
    var speedFloor: Float
    var motionCycle: Float
    var tempo: Float
    var response: Float
    var energy: Float
    var turbulence: Float
    var pulse: Float
    var desaturation: Float
    var volume: Float
    var refraction: Float
    var compression: Float = 0

    mutating func approach(_ target: Self, factor: Float) {
        primary += (target.primary - primary) * factor
        secondary += (target.secondary - secondary) * factor
        accent += (target.accent - accent) * factor
        speed += (target.speed - speed) * factor
        speedFloor += (target.speedFloor - speedFloor) * factor
        motionCycle += (target.motionCycle - motionCycle) * factor
        tempo += (target.tempo - tempo) * factor
        response += (target.response - response) * factor
        energy += (target.energy - energy) * factor
        turbulence += (target.turbulence - turbulence) * factor
        pulse += (target.pulse - pulse) * factor
        desaturation += (target.desaturation - desaturation) * factor
        volume += (target.volume - volume) * factor
        refraction += (target.refraction - refraction) * factor
        compression += (target.compression - compression) * factor
    }
}

private func particleRGBA(
    _ red: Float,
    _ green: Float,
    _ blue: Float,
    _ alpha: Float = 1
) -> SIMD4<Float> {
    SIMD4<Float>(red, green, blue, alpha)
}

private extension Optional where Wrapped == TaskPhase {
    var particleOrbStyle: ParticleOrbStyle {
        switch self {
        case nil:
            ParticleOrbStyle(
                primary: particleRGBA(0.13, 0.17, 0.24),
                secondary: particleRGBA(0.28, 0.34, 0.44),
                accent: particleRGBA(0.48, 0.57, 0.70),
                speed: 0.032, speedFloor: 0.24, motionCycle: 17.0,
                tempo: 0.44, response: 1.15, energy: 0.46,
                turbulence: 0.08, pulse: 0.06, desaturation: 0.34,
                volume: 0.38, refraction: 0.42
            )
        case .some(.starting):
            ParticleOrbStyle(
                primary: particleRGBA(0.12, 0.23, 0.42),
                secondary: particleRGBA(0.25, 0.35, 0.58),
                accent: particleRGBA(0.44, 0.56, 0.75),
                speed: 0.045, speedFloor: 0.28, motionCycle: 16.0,
                tempo: 0.58, response: 1.25, energy: 0.50,
                turbulence: 0.12, pulse: 0.05, desaturation: 0.18,
                volume: 0.44, refraction: 0.50
            )
        case .some(.working):
            ParticleOrbStyle(
                primary: particleRGBA(0.20, 0.12, 0.68),
                secondary: particleRGBA(0.50, 0.23, 0.88),
                accent: particleRGBA(0.34, 0.57, 1.00),
                speed: 0.14, speedFloor: 0.22, motionCycle: 11.0,
                tempo: 0.82, response: 1.55, energy: 0.86,
                turbulence: 0.34, pulse: 0.18, desaturation: 0,
                volume: 0.76, refraction: 0.74
            )
        case .some(.usingTool):
            ParticleOrbStyle(
                primary: particleRGBA(0.04, 0.30, 0.78),
                secondary: particleRGBA(0.02, 0.65, 0.90),
                accent: particleRGBA(0.28, 0.94, 0.84),
                speed: 0.24, speedFloor: 0.18, motionCycle: 8.5,
                tempo: 1.05, response: 1.85, energy: 1.02,
                turbulence: 0.58, pulse: 0.22, desaturation: 0,
                volume: 0.94, refraction: 0.84
            )
        case .some(.waitingApproval):
            ParticleOrbStyle(
                primary: particleRGBA(0.55, 0.21, 0.02),
                secondary: particleRGBA(0.95, 0.46, 0.05),
                accent: particleRGBA(1.00, 0.78, 0.22),
                speed: 0.075, speedFloor: 0.18, motionCycle: 12.0,
                tempo: 0.72, response: 1.45, energy: 0.92,
                turbulence: 0.20, pulse: 0.46, desaturation: 0,
                volume: 0.68, refraction: 0.82
            )
        case .some(.completed):
            ParticleOrbStyle(
                primary: particleRGBA(0.02, 0.38, 0.22),
                secondary: particleRGBA(0.05, 0.70, 0.40),
                accent: particleRGBA(0.36, 0.95, 0.65),
                speed: 0.055, speedFloor: 0.20, motionCycle: 13.0,
                tempo: 0.55, response: 1.20, energy: 0.82,
                turbulence: 0.12, pulse: 0.12, desaturation: 0,
                volume: 0.62, refraction: 0.68
            )
        case .some(.failed):
            ParticleOrbStyle(
                primary: particleRGBA(0.55, 0.01, 0.05),
                secondary: particleRGBA(0.92, 0.08, 0.14),
                accent: particleRGBA(1.00, 0.36, 0.22),
                speed: 0.13, speedFloor: 0.22, motionCycle: 8.0,
                tempo: 0.92, response: 2.10, energy: 0.96,
                turbulence: 0.62, pulse: 0.28, desaturation: 0,
                volume: 0.82, refraction: 0.62
            )
        case .some(.ended):
            ParticleOrbStyle(
                primary: particleRGBA(0.23, 0.25, 0.30),
                secondary: particleRGBA(0.36, 0.38, 0.43),
                accent: particleRGBA(0.50, 0.53, 0.58),
                speed: 0.015, speedFloor: 0.15, motionCycle: 18.0,
                tempo: 0.28, response: 1.00, energy: 0.36,
                turbulence: 0.03, pulse: 0, desaturation: 0.88,
                volume: 0.24, refraction: 0.18
            )
        }
    }
}

private func particleMotionSpeedMultiplier(
    elapsed: Float,
    speedFloor: Float,
    cycle: Float
) -> Float {
    let safeCycle = max(cycle, 0.001)
    let position = max(elapsed, 0)
        .truncatingRemainder(dividingBy: safeCycle) / safeCycle
    let envelope = 0.5 - 0.5 * cos(position * 2 * .pi)
    let floor = min(max(speedFloor, 0), 1)
    return floor + (1 - floor) * envelope
}

private func particleCompressionPulse(elapsed: Float, cycle: Float) -> Float {
    let safeCycle = max(cycle, 0.001)
    let position = max(elapsed, 0)
        .truncatingRemainder(dividingBy: safeCycle) / safeCycle
    return 0.5 - 0.5 * cos(position * 2 * .pi)
}

private func particleCompressionBounce(elapsed: Float, cycle: Float) -> Float {
    let safeCycle = max(cycle, 0.001)
    let phase = max(elapsed, 0)
        .truncatingRemainder(dividingBy: safeCycle) / safeCycle

    func raisedCosinePulse(center: Float, halfWidth: Float) -> Float {
        let distance = abs(phase - center)
        guard distance < halfWidth else { return 0 }
        return 0.5 + 0.5 * cos(.pi * distance / halfWidth)
    }

    let primary = raisedCosinePulse(center: 0.34, halfWidth: 0.20)
    let rebound = raisedCosinePulse(center: 0.64, halfWidth: 0.14) * 0.46
    return max(primary, rebound)
}

private struct ParticleOrbUniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var motionPhase: Float
    var energy: Float
    var turbulence: Float
    var pulse: Float
    var desaturation: Float
    var volume: Float
    var refraction: Float
    var tempo: Float
    var motionEnergy: Float
    var compression: Float
    var compressionPulse: Float
    var compressionBounce: Float
    var reserved1: Float
    var primary: SIMD4<Float>
    var secondary: SIMD4<Float>
    var accent: SIMD4<Float>
}

private enum ParticleOrbRendererError: Error {
    case missingShader
    case invalidShader
    case unavailableMetal
    case missingFunction
    case missingCommandQueue
}

private enum ParticleOrbShaderResource {
    static func source() throws -> String {
        let name = "CodexActivityParticleOrbShader"
        if let bundledURL = Bundle.main.url(forResource: name, withExtension: "txt") {
            guard let source = String(
                data: try Data(contentsOf: bundledURL),
                encoding: .utf8
            ) else { throw ParticleOrbRendererError.invalidShader }
            return source
        }

        let checkoutURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent(name)
            .appendingPathExtension("txt")
        guard FileManager.default.fileExists(atPath: checkoutURL.path),
              let source = String(
                data: try Data(contentsOf: checkoutURL),
                encoding: .utf8
              )
        else { throw ParticleOrbRendererError.missingShader }
        return source
    }
}

private final class ParticleOrbRenderer: NSObject, MTKViewDelegate {
    private static let motionSpeedScale: Float = 16.0
    private static let compressionCycle: Float = 3.2

    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let startTime = CACurrentMediaTime()
    private var lastFrameTime = CACurrentMediaTime()
    private var currentStyle: ParticleOrbStyle
    private var targetStyle: ParticleOrbStyle
    private var activePhase: TaskPhase?
    private var reduceMotion = false
    private var stateElapsed: Float = 0
    private var motionPhase: Float = 0

    init(view: MTKView, initialPhase: TaskPhase?) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw ParticleOrbRendererError.unavailableMetal
        }
        guard let queue = device.makeCommandQueue() else {
            throw ParticleOrbRendererError.missingCommandQueue
        }

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.framebufferOnly = true
        view.wantsLayer = true
        view.layer?.isOpaque = false

        let library = try device.makeLibrary(
            source: ParticleOrbShaderResource.source(),
            options: nil
        )
        guard let vertex = library.makeFunction(name: "activityOrbVertex"),
              let fragment = library.makeFunction(name: "activityOrbFragment")
        else { throw ParticleOrbRendererError.missingFunction }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "QuotaView Particle Orb"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        if let attachment = descriptor.colorAttachments[0] {
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }
        pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        commandQueue = queue
        currentStyle = initialPhase.particleOrbStyle
        targetStyle = initialPhase.particleOrbStyle
        activePhase = initialPhase
        super.init()
        view.delegate = self
    }

    func setPhase(_ phase: TaskPhase?) {
        if phase != activePhase {
            activePhase = phase
            stateElapsed = 0
        }
        targetStyle = phase.particleOrbStyle
        if reduceMotion { currentStyle = targetStyle }
    }

    func setReduceMotion(_ enabled: Bool, in view: MTKView) {
        guard reduceMotion != enabled else { return }
        reduceMotion = enabled
        if enabled {
            currentStyle = targetStyle
            view.isPaused = true
            view.enableSetNeedsDisplay = true
            view.needsDisplay = true
        } else {
            stateElapsed = 0
            lastFrameTime = CACurrentMediaTime()
            view.enableSetNeedsDisplay = false
            view.isPaused = false
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let now = CACurrentMediaTime()
        let delta = Float(min(now - lastFrameTime, 1.0 / 15.0))
        lastFrameTime = now
        if reduceMotion {
            currentStyle = targetStyle
        } else {
            let transition = min(1, delta * max(0.4, targetStyle.response))
            currentStyle.approach(targetStyle, factor: transition)
            stateElapsed += delta
            motionPhase += delta * currentStyle.speed
                * particleMotionSpeedMultiplier(
                    elapsed: stateElapsed,
                    speedFloor: currentStyle.speedFloor,
                    cycle: currentStyle.motionCycle
                )
                * Self.motionSpeedScale
            if motionPhase > 4096 {
                motionPhase.formTruncatingRemainder(dividingBy: 4096)
            }
        }

        let motionEnergy = reduceMotion ? Float(0) : particleMotionSpeedMultiplier(
            elapsed: stateElapsed,
            speedFloor: 0,
            cycle: currentStyle.motionCycle
        )
        let compressionPulse = reduceMotion ? Float(0.72) : particleCompressionPulse(
            elapsed: stateElapsed,
            cycle: Self.compressionCycle
        )
        let compressionBounce = reduceMotion ? Float(0.68) : particleCompressionBounce(
            elapsed: stateElapsed,
            cycle: Self.compressionCycle
        )
        var uniforms = ParticleOrbUniforms(
            resolution: SIMD2<Float>(
                Float(max(view.drawableSize.width, 1)),
                Float(max(view.drawableSize.height, 1))
            ),
            time: reduceMotion ? 0.35 : Float(now - startTime),
            motionPhase: motionPhase,
            energy: currentStyle.energy,
            turbulence: reduceMotion ? 0.04 : currentStyle.turbulence,
            pulse: reduceMotion ? 0 : currentStyle.pulse,
            desaturation: currentStyle.desaturation,
            volume: currentStyle.volume,
            refraction: currentStyle.refraction,
            tempo: reduceMotion ? 0 : currentStyle.tempo,
            motionEnergy: motionEnergy,
            compression: currentStyle.compression,
            compressionPulse: compressionPulse,
            compressionBounce: compressionBounce,
            reserved1: 0,
            primary: currentStyle.primary,
            secondary: currentStyle.secondary,
            accent: currentStyle.accent
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<ParticleOrbUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

private final class ParticleOrbMetalView: MTKView {
    private var renderer: ParticleOrbRenderer?
    var isRendererAvailable: Bool { renderer != nil }

    init(frame: NSRect, initialPhase: TaskPhase?) {
        super.init(frame: frame, device: MTLCreateSystemDefaultDevice())
        renderer = try? ParticleOrbRenderer(view: self, initialPhase: initialPhase)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPhase(_ phase: TaskPhase?) {
        renderer?.setPhase(phase)
        if isPaused { needsDisplay = true }
    }

    func setReduceMotion(_ enabled: Bool) {
        renderer?.setReduceMotion(enabled, in: self)
    }

    func redrawIfPaused() {
        if isPaused { needsDisplay = true }
    }
}

final class ParticleOrbHostView: NSView {
    private let metalView: ParticleOrbMetalView
    private let fallback = ParticleOrbFallbackView()
    override var isOpaque: Bool { false }

    init(phase: TaskPhase?, animated: Bool) {
        metalView = ParticleOrbMetalView(frame: .zero, initialPhase: phase)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(fallback)
        addSubview(metalView)
        fallback.isHidden = metalView.isRendererAvailable
        metalView.isHidden = !metalView.isRendererAvailable
        update(phase: phase, animated: animated)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        fallback.frame = bounds
        metalView.redrawIfPaused()
    }

    func update(phase: TaskPhase?, animated: Bool) {
        metalView.setPhase(phase)
        metalView.setReduceMotion(!animated)
        fallback.color = phase?.color ?? .gray
    }
}

private final class ParticleOrbFallbackView: NSView {
    var color: Color = .gray { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let side = min(bounds.width, bounds.height) * 0.535
        let rect = NSRect(
            x: bounds.midX - side / 2,
            y: bounds.midY - side / 2,
            width: side,
            height: side
        )
        let path = NSBezierPath(ovalIn: rect)
        let nsColor = NSColor(color)
        NSGradient(colors: [
            nsColor.withAlphaComponent(0.18),
            nsColor.withAlphaComponent(0.64),
            NSColor.white.withAlphaComponent(0.36),
        ])?.draw(in: path, angle: 38)
        nsColor.withAlphaComponent(0.64).setStroke()
        path.lineWidth = 0.8
        path.stroke()
    }
}

enum ParticleOrbRuntimeValidator {
    static func validationError() -> String? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        do {
            let source = try ParticleOrbShaderResource.source()
            guard source.contains("vertex VertexOut activityOrbVertex"),
                  source.contains("fragment float4 activityOrbFragment"),
                  source.contains("constexpr int sampleCount = 20")
            else { return "QuotaView Particle Orb shader resource is incomplete" }
            let library = try device.makeLibrary(source: source, options: nil)
            guard library.makeFunction(name: "activityOrbVertex") != nil,
                  library.makeFunction(name: "activityOrbFragment") != nil
            else { return "QuotaView Particle Orb shader functions are missing" }
        } catch {
            return "Particle Orb Metal validation failed: \(error.localizedDescription)"
        }
        return nil
    }
}
