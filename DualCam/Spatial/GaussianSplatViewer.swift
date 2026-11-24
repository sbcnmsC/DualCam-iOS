import Foundation
import Metal
import MetalKit
import MetalSplatter
import SwiftUI
import simd

private struct GaussianSceneBounds {
    let center: SIMD3<Float>
    let radius: Float

    static func read(from plyURL: URL) -> GaussianSceneBounds {
        let manifestURL = plyURL.deletingLastPathComponent().appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bounds = object["sceneBounds"] as? [String: Any],
              let minimum = bounds["min"] as? [NSNumber],
              let maximum = bounds["max"] as? [NSNumber],
              minimum.count == 3, maximum.count == 3 else {
            return GaussianSceneBounds(center: .zero, radius: 1)
        }

        let low = SIMD3<Float>(minimum[0].floatValue, minimum[1].floatValue, minimum[2].floatValue)
        let high = SIMD3<Float>(maximum[0].floatValue, maximum[1].floatValue, maximum[2].floatValue)
        let center = (low + high) * 0.5
        let radius = max(simd_length(high - low) * 0.5, 0.08)
        return GaussianSceneBounds(center: center, radius: radius)
    }
}

struct GaussianSplatViewerScreen: View {
    let url: URL

    @Environment(\.dismiss) private var dismiss
    @State private var yaw: Float = 0
    @State private var pitch: Float = 0.12
    @State private var distance: Float = 2
    @State private var pan = SIMD2<Float>.zero
    @State private var target = SIMD3<Float>.zero
    @State private var baseDistance: Float = 2
    @State private var dragOrigin = CGSize.zero
    @State private var isPanMode = false
    @State private var isAutoRotate = false
    @State private var loadStatus = "正在载入 Gaussian 场景…"
    @State private var splatCount = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GaussianSplatMetalView(
                url: url,
                yaw: yaw,
                pitch: pitch,
                distance: distance,
                target: target + SIMD3<Float>(pan.x, pan.y, 0),
                isAutoRotate: isAutoRotate,
                onStatus: { status, count in
                    loadStatus = status
                    splatCount = count
                }
            )
            .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.65), .clear, .black.opacity(0.68)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("3D 场景")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                        Text(splatCount > 0 ? "\(splatCount.formatted()) 个 Gaussian" : loadStatus)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.68))
                    }

                    Spacer()

                    Button {
                        isAutoRotate.toggle()
                    } label: {
                        Image(systemName: isAutoRotate ? "pause.fill" : "rotate.3d")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isAutoRotate ? .yellow : .white)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel(isAutoRotate ? "停止自动旋转" : "自动旋转")

                    Button {
                        resetCamera()
                    } label: {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("重置视角")
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)

                Spacer()

                VStack(spacing: 12) {
                    HStack(spacing: 8) {
                        modeButton(title: "旋转", icon: "rotate.3d", selected: !isPanMode) {
                            isPanMode = false
                        }
                        modeButton(title: "平移", icon: "hand.draw", selected: isPanMode) {
                            isPanMode = true
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "hand.draw")
                        Text(isPanMode ? "拖动平移 · 双指捏合缩放" : "拖动环绕 · 双指捏合缩放")
                        Spacer()
                        ShareLink(item: url) {
                            Label("导出 PLY", systemImage: "square.and.arrow.up")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.74))
                }
                .padding(14)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 18)
            }
        }
        .statusBarHidden(true)
        .gesture(dragGesture)
        .simultaneousGesture(magnificationGesture)
        .onAppear(perform: setInitialCamera)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                let dx = value.translation.width - dragOrigin.width
                let dy = value.translation.height - dragOrigin.height
                dragOrigin = value.translation

                if isPanMode {
                    let worldUnitsPerPoint = distance * 0.0018
                    pan.x -= Float(dx) * worldUnitsPerPoint
                    pan.y += Float(dy) * worldUnitsPerPoint
                } else {
                    yaw -= Float(dx) * 0.008
                    pitch = min(max(pitch + Float(dy) * 0.006, -1.35), 1.35)
                }
            }
            .onEnded { _ in dragOrigin = .zero }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                distance = min(max(baseDistance / Float(scale), 0.08), 80)
            }
            .onEnded { _ in baseDistance = distance }
    }

    private func modeButton(title: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? .black : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(selected ? Color.white : Color.white.opacity(0.10), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func setInitialCamera() {
        let bounds = GaussianSceneBounds.read(from: url)
        target = bounds.center
        distance = max(bounds.radius * 2.8, 0.25)
        baseDistance = distance
    }

    private func resetCamera() {
        yaw = 0
        pitch = 0.12
        pan = .zero
        setInitialCamera()
    }
}

private struct GaussianSplatMetalView: UIViewRepresentable {
    let url: URL
    let yaw: Float
    let pitch: Float
    let distance: Float
    let target: SIMD3<Float>
    let isAutoRotate: Bool
    let onStatus: (String, Int) -> Void

    final class Coordinator {
        var renderer: GaussianSplatMetalRenderer?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.sampleCount = 1
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0.012, green: 0.016, blue: 0.026, alpha: 1)

        if let renderer = GaussianSplatMetalRenderer(
            view: view,
            url: url,
            onStatus: onStatus
        ) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        } else {
            onStatus("此设备没有可用的 Metal GPU", 0)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.updateCamera(
            yaw: yaw,
            pitch: pitch,
            distance: distance,
            target: target,
            autoRotate: isAutoRotate
        )
    }

    static func dismantleUIView(_ view: MTKView, coordinator: Coordinator) {
        view.delegate = nil
        coordinator.renderer?.stop()
        coordinator.renderer = nil
    }
}

@MainActor
private final class GaussianSplatMetalRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let inFlight = DispatchSemaphore(value: 2)

    private var splatRenderer: SplatRenderer?
    private var drawableSize = CGSize.zero
    private var yaw: Float = 0
    private var pitch: Float = 0.12
    private var distance: Float = 2
    private var target = SIMD3<Float>.zero
    private var autoRotate = false
    private var lastFrameTime = CACurrentMediaTime()
    private var stopped = false

    private let onStatus: (String, Int) -> Void

    init?(view: MTKView, url: URL, onStatus: @escaping (String, Int) -> Void) {
        guard let device = view.device,
              let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.onStatus = onStatus
        super.init()

        Task { [weak self] in
            await self?.loadScene(url)
        }
    }

    func updateCamera(yaw: Float, pitch: Float, distance: Float, target: SIMD3<Float>, autoRotate: Bool) {
        self.yaw = yaw
        self.pitch = pitch
        self.distance = distance
        self.target = target
        self.autoRotate = autoRotate
    }

    func stop() {
        stopped = true
        splatRenderer = nil
    }

    private func loadScene(_ url: URL) async {
        do {
            onStatus("正在解析 PLY 并上传 GPU…", 0)
            let renderer = try SplatRenderer(
                device: device,
                colorFormat: .bgra8Unorm_srgb,
                depthFormat: .depth32Float,
                sampleCount: 1,
                maxViewCount: 1,
                maxSimultaneousRenders: 2
            )
            try await renderer.read(from: url)
            guard !stopped else { return }
            splatRenderer = renderer
            onStatus("Metal Gaussian 渲染已就绪", renderer.splatCount)
        } catch {
            onStatus("PLY 载入失败：\(error.localizedDescription)", 0)
        }
    }

    func draw(in view: MTKView) {
        guard !stopped, let splatRenderer, let drawable = view.currentDrawable else { return }
        guard inFlight.wait(timeout: .now()) == .success else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlight.signal()
            return
        }

        let semaphore = inFlight
        commandBuffer.addCompletedHandler { _ in semaphore.signal() }

        let now = CACurrentMediaTime()
        let delta = Float(min(max(now - lastFrameTime, 0), 0.05))
        lastFrameTime = now
        if autoRotate { yaw += delta * 0.28 }

        let size = view.drawableSize
        guard size.width > 1, size.height > 1 else {
            commandBuffer.commit()
            return
        }
        let viewport = MTLViewport(
            originX: 0,
            originY: 0,
            width: size.width,
            height: size.height,
            znear: 0,
            zfar: 1
        )
        let projection = Self.perspective(
            fovY: 62 * .pi / 180,
            aspect: Float(size.width / size.height),
            near: 0.01,
            far: 250
        )
        let viewMatrix = Self.lookAt(
            eye: cameraPosition(),
            target: target,
            up: SIMD3<Float>(0, 1, 0)
        )
        let descriptor = SplatRenderer.ViewportDescriptor(
            viewport: viewport,
            projectionMatrix: projection,
            viewMatrix: viewMatrix,
            screenSize: SIMD2<Int>(Int(size.width), Int(size.height))
        )

        do {
            try splatRenderer.render(
                viewports: [descriptor],
                colorTexture: view.multisampleColorTexture ?? drawable.texture,
                colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                depthTexture: view.depthStencilTexture,
                rasterizationRateMap: nil,
                renderTargetArrayLength: 0,
                to: commandBuffer
            )
            commandBuffer.present(drawable)
        } catch {
            onStatus("Metal 渲染失败：\(error.localizedDescription)", splatRenderer.splatCount)
        }
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }

    private func cameraPosition() -> SIMD3<Float> {
        let horizontal = cos(pitch)
        let offset = SIMD3<Float>(
            sin(yaw) * horizontal,
            sin(pitch),
            cos(yaw) * horizontal
        ) * distance
        return target + offset
    }

    private static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let safeAspect = max(aspect, 0.001)
        let yScale = 1 / tan(fovY * 0.5)
        let xScale = yScale / safeAspect
        let zScale = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(xScale, 0, 0, 0),
            SIMD4<Float>(0, yScale, 0, 0),
            SIMD4<Float>(0, 0, zScale, -1),
            SIMD4<Float>(0, 0, zScale * near, 0)
        )
    }

    private static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let correctedUp = simd_cross(right, forward)
        return simd_float4x4(
            SIMD4<Float>(right.x, correctedUp.x, -forward.x, 0),
            SIMD4<Float>(right.y, correctedUp.y, -forward.y, 0),
            SIMD4<Float>(right.z, correctedUp.z, -forward.z, 0),
            SIMD4<Float>(
                -simd_dot(right, eye),
                -simd_dot(correctedUp, eye),
                simd_dot(forward, eye),
                1
            )
        )
    }
}
