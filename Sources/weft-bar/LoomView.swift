import AppKit
import MetalKit
import SwiftUI

/// The stage behind Setup: a loom in the dark, weaving an accent thread. The
/// cloth grows as the pages go by, every page change beats the reed, and the
/// pointer plucks the warp under it. With Reduce Motion the loom holds still.
struct LoomBackdrop: View, Animatable {
    let accent: Color
    /// 0…1 across the pages: the fell of the cloth rises with it. Animatable,
    /// so a page change raises the cloth instead of jumping it.
    var progress: Double
    /// Changes when the page does: time for a beat.
    let beatID: Int

    nonisolated var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let ink = Color(.sRGB, red: 0.043, green: 0.047, blue: 0.07, opacity: 1)

    var body: some View {
        LoomView(accent: accent, progress: progress, beatID: beatID, isStill: reduceMotion)
            .background(Self.ink)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }
}

/// Draws `LoomShader` full-bleed. SwiftUI hands it the progress, the accent
/// and a beat counter; time and the pointer are tracked here, so the loom
/// moves at display rate without re-running any SwiftUI body.
struct LoomView: NSViewRepresentable {
    let accent: Color
    let progress: Double
    let beatID: Int
    let isStill: Bool

    func makeCoordinator() -> Renderer { Renderer() }

    func makeNSView(context: Context) -> LoomMTKView {
        let view = LoomMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.renderer = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        // The threads are soft at this size: one pixel per point is enough,
        // and on Retina that is a quarter of the fragments.
        view.autoResizeDrawable = false
        view.clearColor = MTLClearColor(red: 0.043, green: 0.047, blue: 0.07, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.prepare(device: view.device)
        return view
    }

    func updateNSView(_ view: LoomMTKView, context: Context) {
        let renderer = context.coordinator
        renderer.progress = progress
        renderer.accent = NSColor(accent).usingColorSpace(.sRGB).map {
            SIMD4(Float($0.redComponent), Float($0.greenComponent), Float($0.blueComponent), 1)
        } ?? SIMD4(0.478, 0.635, 0.968, 1)
        if renderer.beatID != beatID {
            if renderer.beatID != nil, !isStill { renderer.beatNow() }
            renderer.beatID = beatID
        }
        renderer.isStill = isStill
        view.isStill = isStill
        view.needsDisplay = true
    }

    /// Tracks the pointer itself: SwiftUI hover would re-render the view on
    /// every move.
    final class LoomMTKView: MTKView {
        weak var renderer: Renderer?
        private var tracking: NSTrackingArea?
        private var occlusionObserver: NSObjectProtocol?

        /// Reduce Motion: draw on demand only.
        var isStill = false {
            didSet { if isStill != oldValue { updatePaused() } }
        }

        /// Runs only while someone can see it. Otherwise it draws on demand,
        /// which is once per change — so a covered or hidden Setup costs no GPU,
        /// and the frame is still right the moment it is uncovered.
        private func updatePaused() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            let animating = visible && !isStill
            isPaused = !animating
            enableSetNeedsDisplay = !animating
            needsDisplay = true
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
            occlusionObserver = window.map { window in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updatePaused() }
                }
            }
            updatePaused()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            let point = convert(event.locationInWindow, from: nil)
            renderer?.pointerMoved(to: CGPoint(x: point.x, y: isFlipped ? point.y : bounds.height - point.y))
        }
    }

    /// Layout must match `Uniforms` in the shader: SIMD alignment is the same
    /// on both sides.
    private struct Uniforms {
        var size: SIMD2<Float>
        var pointer: SIMD2<Float>
        var time: Float
        var beatAge: Float
        var progress: Float
        var pointerStrength: Float
        var contentScale: Float
        var accent: SIMD4<Float>
    }

    @MainActor
    final class Renderer: NSObject, MTKViewDelegate {
        var progress: Double = 0
        var accent = SIMD4<Float>(0.478, 0.635, 0.968, 1)
        var beatID: Int?
        var isStill = false

        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private let start = CACurrentMediaTime()
        private var beatAt: Double?
        private var pointer: (point: SIMD2<Float>, time: Double)?

        private var now: Double { isStill ? 0 : CACurrentMediaTime() - start }

        func prepare(device: MTLDevice?) {
            guard let device else { return }
            queue = device.makeCommandQueue()
            do {
                let library = try device.makeLibrary(source: LoomShader.source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "loomVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "loomFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                // The clear colour (plain ink) stands in; Setup still works.
                assertionFailure("Loom shader failed: \(error)")
            }
        }

        func beatNow() { beatAt = now }

        func pointerMoved(to point: CGPoint) {
            guard !isStill else { return }
            pointer = (SIMD2(Float(point.x), Float(point.y)), now)
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { render(in: view) }
        }

        private func render(in view: MTKView) {
            let size = view.bounds.size
            guard size.width > 0, size.height > 0 else { return }
            let pixels = CGSize(width: size.width.rounded(), height: size.height.rounded())
            if view.drawableSize != pixels { view.drawableSize = pixels }
            guard let pipeline, let queue, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
            else { return }
            let t = now
            var uniforms = Uniforms(
                size: SIMD2(Float(size.width), Float(size.height)),
                pointer: pointer?.point ?? SIMD2(-1000, -1000),
                time: Float(t),
                beatAge: beatAt.map { Float(t - $0) } ?? 100,
                progress: Float(progress),
                pointerStrength: pointer.map { Float(max(0, 1 - (t - $0.time) / 1.2)) } ?? 0,
                contentScale: Float(pixels.width / size.width),
                accent: accent
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}
