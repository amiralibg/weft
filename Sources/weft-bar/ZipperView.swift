import AppKit
import MetalKit
import SwiftUI

/// The cloth over Setup's stage, zipped shut down the middle. Each step pulls
/// the slider further down and the loom shows through the gap above it; on
/// the last page the slider runs off the bottom and the two halves swing
/// apart, uncovering the Done page laid out underneath. With Reduce Motion the
/// zip moves without springing.
struct ZipperBackdrop: View {
    let accent: Color
    /// 0…1 down the track.
    let progress: Double
    /// The zip comes undone and the halves part.
    let isOpen: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZipperView(accent: accent, progress: progress, isOpen: isOpen, isStill: reduceMotion)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Draws `ZipperShader` full-bleed over whatever is behind it. SwiftUI hands
/// it where the slider should be and whether the zip is undone; the slider's
/// spring, the tab's swing, time and the pointer all live in the renderer, so
/// nothing in SwiftUI re-renders per frame.
struct ZipperView: NSViewRepresentable {
    let accent: Color
    let progress: Double
    let isOpen: Bool
    let isStill: Bool

    func makeCoordinator() -> Renderer { Renderer() }

    func makeNSView(context: Context) -> ZipperMTKView {
        let view = ZipperMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.renderer = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        // Full resolution, unlike the loom: teeth and bevels are hard-edged
        // metal, and at one pixel per point they go soft. MTKView keeps the
        // drawable at the backing scale by itself; sized by hand, the layer
        // shows it at one pixel per point, top-left, twice as large.
        view.autoResizeDrawable = true
        // Transparent wherever the cloth has parted: the loom and the Done
        // page underneath show through.
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.delegate = context.coordinator
        context.coordinator.prepare(device: view.device)
        return view
    }

    func updateNSView(_ view: ZipperMTKView, context: Context) {
        let renderer = context.coordinator
        renderer.accent = NSColor(accent).usingColorSpace(.sRGB).map {
            SIMD4(Float($0.redComponent), Float($0.greenComponent), Float($0.blueComponent), 1)
        } ?? SIMD4(0.478, 0.635, 0.968, 1)
        renderer.isStill = isStill
        renderer.pull(to: progress, open: isOpen)
        view.isStill = isStill
        view.wake()
    }

    /// Tracks the pointer itself (SwiftUI hover would re-render the view on
    /// every move) and lets every click through to the page underneath.
    final class ZipperMTKView: MTKView {
        weak var renderer: Renderer?
        private var tracking: NSTrackingArea?
        private var occlusionObserver: NSObjectProtocol?

        /// Reduce Motion: draw on demand only.
        var isStill = false {
            didSet { if isStill != oldValue { updatePaused() } }
        }

        /// The cloth is decoration. The Done page sits *under* it, and its
        /// buttons have to be reachable the moment the halves have gone.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private var isVisible: Bool { window?.occlusionState.contains(.visible) ?? false }

        /// Runs only while someone can see it, as the loom does.
        private func updatePaused() {
            setRunning(isVisible && !isStill)
        }

        private func setRunning(_ running: Bool) {
            isPaused = !running
            enableSetNeedsDisplay = !running
            needsDisplay = true
        }

        /// Something moved: the slider has somewhere to go, or the pointer
        /// brushed the tab. Draw every frame until it has all come to rest.
        ///
        /// Occlusion alone cannot be trusted to start the frames. Setup's
        /// window is built long before it is first shown, so this view joins
        /// it while it is still hidden, and the change that should follow is
        /// not always posted — the zip then drew one frame per page change,
        /// and each frame moved the spring by a thirtieth of a second: the
        /// slider jumped a little and stopped where it was.
        func wake() {
            setRunning(!isStill)
        }

        /// Called by the renderer once nothing is moving. Idle glints and the
        /// tab's sway carry on only while the window can be seen.
        func cameToRest() {
            if !isPaused && !isVisible { setRunning(false) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            layer?.isOpaque = false
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
            wake()
        }
    }

    /// Layout must match `Uniforms` in the shader: SIMD alignment is the same
    /// on both sides.
    private struct Uniforms {
        var size: SIMD2<Float>
        var pointer: SIMD2<Float>
        var time: Float
        var sliderY: Float
        var release: Float
        var tabAngle: Float
        var pointerStrength: Float
        var contentScale: Float
        var accent: SIMD4<Float>
    }

    @MainActor
    final class Renderer: NSObject, MTKViewDelegate {
        var accent = SIMD4<Float>(0.478, 0.635, 0.968, 1)
        var isStill = false

        private var queue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private let start = CACurrentMediaTime()
        private var lastFrame: Double?
        private var pointer: (point: SIMD2<Float>, time: Double)?
        private var size = CGSize.zero

        /// Where SwiftUI wants the slider, and whether the zip is undone.
        private var target = 0.0
        private var isOpen = false
        /// The slider, on a spring: 0 at the top stop, 1 at the bottom one.
        private var slider = 0.0
        private var velocity = 0.0
        /// 0…1 through coming undone: the slider leaves, then the halves part.
        private var release = 0.0
        /// The pull tab, a pendulum on the slider's lug.
        private var tab = 0.0
        private var tabVelocity = 0.0
        /// Each pull swings the tab the other way from the last.
        private var kickSign = 1.0

        private var now: Double { isStill ? 0 : CACurrentMediaTime() - start }

        func prepare(device: MTLDevice?) {
            guard let device else { return }
            queue = device.makeCommandQueue()
            do {
                let library = try device.makeLibrary(source: ZipperShader.source, options: nil)
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: "zipperVertex")
                descriptor.fragmentFunction = library.makeFunction(name: "zipperFragment")
                descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
                pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                // Nothing is drawn: the loom shows through, and Setup still works.
                assertionFailure("Zipper shader failed: \(error)")
            }
        }

        func pull(to progress: Double, open: Bool) {
            let next = min(max(progress, 0), 1)
            if lastFrame != nil, abs(next - target) > 0.001 {
                // A tug on the slider flicks the tab; a bigger pull, a bigger flick.
                tabVelocity += kickSign * (1.2 + 4 * abs(next - target))
                kickSign = -kickSign
            }
            target = next
            isOpen = open
        }

        func pointerMoved(to point: CGPoint) {
            guard !isStill else { return }
            let next = SIMD2(Float(point.x), Float(point.y))
            if let last = pointer, size.height > 0 {
                // Brushing past the tab sets it swinging.
                let tabCenter = SIMD2(Float(size.width / 2), Float((sliderY + 0.065) * size.height))
                let distance = simd_length(next - tabCenter)
                if distance < 70 {
                    let push = Double(next.x - last.point.x) * 0.05 * Double(1 - distance / 70)
                    tabVelocity += min(max(push, -2), 2)
                }
            }
            pointer = (next, now)
        }

        /// The slider's centre, in height units. Its last stop sits above
        /// Setup's controls; coming undone carries it off the bottom.
        private var sliderY: Double {
            let leave = min(release / 0.45, 1)
            return 0.075 + 0.765 * slider + leave * leave * 0.5
        }

        /// The halves part once the slider is on its way out.
        private var parting: Double {
            let x = min(max((release - 0.2) / 0.8, 0), 1)
            return x * x * (3 - 2 * x)
        }

        private func step(to time: Double) {
            guard let last = lastFrame, !isStill else {
                // First frame, or Reduce Motion: straight to where things rest.
                slider = target
                velocity = 0
                release = isOpen ? 1 : 0
                tab = 0
                tabVelocity = 0
                lastFrame = time
                return
            }
            let dt = min(max(time - last, 0), 1.0 / 30)
            lastFrame = time

            // A heavy slider: quick to start, settling without a bounce.
            let stiffness = 34.0
            let accel = stiffness * (target - slider) - 2 * sqrt(stiffness) * 0.95 * velocity
            velocity += accel * dt
            slider += velocity * dt

            // Undone only once the slider has reached the bottom stop.
            if isOpen && slider > 0.97 {
                release = min(1, release + dt / 1.2)
            } else if !isOpen {
                release = max(0, release - dt / 0.7)
            }

            // The tab hangs from the slider, so the slider speeding up
            // downwards lightens it and its slowing down makes it heavier.
            let gravity = max(6, 30 - accel * 0.765 * 3)
            tabVelocity += (-gravity * sin(tab) - 2.4 * tabVelocity) * dt
            tab = min(max(tab + tabVelocity * dt, -1.3), 1.3)
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { render(in: view) }
        }

        private func render(in view: MTKView) {
            let bounds = view.bounds.size
            guard bounds.width > 0, bounds.height > 0 else { return }
            size = bounds
            let pixels = view.drawableSize
            guard pixels.width > 0, let pipeline, let queue, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
            else { return }
            let t = now
            step(to: isStill ? CACurrentMediaTime() : t)
            // A little life in the tab even at rest.
            let sway = isStill ? 0 : sin(t * 1.1) * 0.025
            var uniforms = Uniforms(
                size: SIMD2(Float(bounds.width), Float(bounds.height)),
                pointer: pointer?.point ?? SIMD2(-1000, -1000),
                time: Float(t),
                sliderY: Float(sliderY),
                release: Float(parting),
                tabAngle: Float(tab + sway),
                pointerStrength: pointer.map { Float(max(0, 1 - (t - $0.time) / 1.2)) } ?? 0,
                contentScale: Float(pixels.width / bounds.width),
                accent: accent
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
            if isAtRest { (view as? ZipperMTKView)?.cameToRest() }
        }

        private var isAtRest: Bool {
            abs(target - slider) < 0.0005 && abs(velocity) < 0.001
                && release == (isOpen ? 1 : 0)
                && abs(tabVelocity) < 0.01 && abs(tab) < 0.01
        }
    }
}
