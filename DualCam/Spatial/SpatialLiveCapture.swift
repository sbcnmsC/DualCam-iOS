import ARKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import RealityKit
import simd
import SwiftUI
import UIKit

/// LiDAR-backed spatial capture. The exported PLY contains depth-initialized Gaussian
/// primitives in ARKit world space; it is deliberately labelled as an initialisation
/// rather than a trained/optimised 3DGS reconstruction.
final class SpatialLiveCaptureManager: NSObject, ObservableObject {
    @Published private(set) var isSupported = false
    @Published private(set) var isCapturing = false
    @Published private(set) var status = "正在准备空间相机…"
    @Published private(set) var frameCount = 0
    @Published private(set) var splatCount = 0
    @Published private(set) var plyURL: URL?
    @Published private(set) var errorMessage: String?

    private let captureQueue = DispatchQueue(label: "dualcam.spatial.capture", qos: .userInitiated)
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // Session attachment/start are called from the main thread. ARSession callbacks and
    // all dataset writes are serialised on captureQueue.
    private weak var arSession: ARSession?
    private var startRequested = false
    private var framePollingTimer: DispatchSourceTimer?
    private var isCapturingOnQueue = false
    private var sessionDirectory: URL?
    private var frameRecords: [[String: Any]] = []
    private var gaussianSeeds: [GaussianSeed] = []
    private var lastSampleTimestamp: TimeInterval = 0
    private var nextFrameIndex = 0

    private let minimumFrameInterval: TimeInterval = 0.18
    private let maximumFrames = 56
    private let maximumSplats = 180_000
    private let sphericalHarmonicDC: Float = 0.28209479177387814

    private struct GaussianSeed {
        let x: Float
        let y: Float
        let z: Float
        let redDC: Float
        let greenDC: Float
        let blueDC: Float
        let opacityLogit: Float
        let scaleX: Float
        let scaleY: Float
        let scaleZ: Float
        let rotationW: Float
        let rotationX: Float
        let rotationY: Float
        let rotationZ: Float
    }

    func attach(session: ARSession) {
        guard arSession !== session else { return }
        arSession = session
        // Keep the ARView-owned delegate intact; frames are sampled from currentFrame.
        if startRequested {
            configureAndRun(session)
        }
    }

    func startSession() {
        startRequested = true
        guard let session = arSession else {
            status = "正在连接 LiDAR 相机…"
            return
        }
        configureAndRun(session)
    }

    private func configureAndRun(_ session: ARSession) {
        guard ARWorldTrackingConfiguration.isSupported else {
            isSupported = false
            errorMessage = "此设备不支持 AR 世界追踪。"
            status = "设备不支持空间采集"
            return
        }

        let depthSemantics: ARConfiguration.FrameSemantics
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            depthSemantics = .smoothedSceneDepth
        } else if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            depthSemantics = .sceneDepth
        } else {
            isSupported = false
            errorMessage = "需要带 LiDAR 扫描仪并支持 ARKit Scene Depth 的设备，例如 iPhone Pro 系列。"
            status = "未检测到可用 LiDAR 深度"
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.frameSemantics = depthSemantics
        isSupported = true
        errorMessage = nil
        status = "LiDAR 深度已就绪，缓慢环绕拍摄对象"
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    private func startFramePollingIfNeeded() {
        guard framePollingTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: captureQueue)
        timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(180), leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in self?.consumeCurrentFrame() }
        framePollingTimer = timer
        timer.resume()
    }

    private func stopFramePolling() {
        framePollingTimer?.setEventHandler {}
        framePollingTimer?.cancel()
        framePollingTimer = nil
    }

    func startCapture() {
        guard isSupported, !isCapturing else { return }
        errorMessage = nil
        plyURL = nil
        captureQueue.async {
            do {
                let documents = try FileManager.default.url(
                    for: .documentDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                let root = documents.appendingPathComponent("DualCam3DLive", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

                self.sessionDirectory = folder
                self.frameRecords.removeAll(keepingCapacity: true)
                self.gaussianSeeds.removeAll(keepingCapacity: true)
                self.lastSampleTimestamp = 0
                self.nextFrameIndex = 0
                self.isCapturingOnQueue = true
                self.startFramePollingIfNeeded()

                DispatchQueue.main.async {
                    self.frameCount = 0
                    self.splatCount = 0
                    self.isCapturing = true
                    self.status = "正在采集彩色帧、深度与相机位姿…"
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.status = "无法创建 3D 实况文件夹"
                }
            }
        }
    }

    func stopCapture() {
        captureQueue.async {
            guard self.isCapturingOnQueue else { return }
            self.isCapturingOnQueue = false
            self.stopFramePolling()
            self.finishDataset()
        }
    }

    /// Called when the full-screen capture view closes. Pause AR first, then drain any
    /// in-flight frame callback and finish the dataset before the ordinary camera resumes.
    func stopSession(completion: @escaping () -> Void) {
        startRequested = false
        arSession?.pause()
        captureQueue.async {
            self.stopFramePolling()
            if self.isCapturingOnQueue {
                self.isCapturingOnQueue = false
                self.finishDataset()
            }
            DispatchQueue.main.async {
                completion()
            }
        }
    }

    private func consumeCurrentFrame() {
        guard isCapturingOnQueue,
              let frame = arSession?.currentFrame,
              frame.timestamp - lastSampleTimestamp >= minimumFrameInterval else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        guard nextFrameIndex < maximumFrames, gaussianSeeds.count < maximumSplats else {
            isCapturingOnQueue = false
            finishDataset()
            return
        }

        do {
            try appendFrame(frame, depthData: depthData)
            lastSampleTimestamp = frame.timestamp
            nextFrameIndex += 1

            if nextFrameIndex >= maximumFrames || gaussianSeeds.count >= maximumSplats {
                isCapturingOnQueue = false
                finishDataset()
            } else {
                let currentFrames = nextFrameIndex
                let currentSplats = gaussianSeeds.count
                DispatchQueue.main.async {
                    self.frameCount = currentFrames
                    self.splatCount = currentSplats
                    self.status = "采集中 · \\(currentFrames)/\\(self.maximumFrames) 帧"
                }
            }
        } catch {
            isCapturingOnQueue = false
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
                self.status = "采集遇到问题，已停止"
            }
            finishDataset()
        }
    }

    private func appendFrame(_ frame: ARFrame, depthData: ARDepthData) throws {
        guard let folder = sessionDirectory else {
            throw CaptureError.captureFolderMissing
        }

        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        let qualityKey = CIImageRepresentationOption(
            rawValue: kCGImageDestinationLossyCompressionQuality as String
        )
        guard let jpegData = ciContext.jpegRepresentation(
            of: image,
            colorSpace: colorSpace,
            options: [qualityKey: 0.84]
        ) else {
            throw CaptureError.imageEncodingFailed
        }

        let frameName = String(format: "frame_%04d", nextFrameIndex)
        let imageURL = folder.appendingPathComponent(frameName).appendingPathExtension("jpg")
        try jpegData.write(to: imageURL, options: .atomic)

        let depthMap = depthData.depthMap
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthBytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        guard CVPixelBufferLockBaseAddress(depthMap, .readOnly) == kCVReturnSuccess,
              let depthBaseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw CaptureError.depthBufferUnavailable
        }
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        let depthDataBytes = Data(
            bytes: depthBaseAddress,
            count: depthBytesPerRow * depthHeight
        )
        let depthURL = folder.appendingPathComponent(frameName).appendingPathExtension("depth-f32")
        try depthDataBytes.write(to: depthURL, options: .atomic)

        let colorPixelBuffer = try makeColorBuffer(from: image)
        guard CVPixelBufferLockBaseAddress(colorPixelBuffer, .readOnly) == kCVReturnSuccess,
              let colorBaseAddress = CVPixelBufferGetBaseAddress(colorPixelBuffer) else {
            throw CaptureError.colorBufferUnavailable
        }
        defer { CVPixelBufferUnlockBaseAddress(colorPixelBuffer, .readOnly) }

        var confidencePointer: UnsafeMutablePointer<UInt8>?
        var confidenceBytesPerRow = 0
        var lockedConfidenceMap: CVPixelBuffer?
        if let confidenceMap = depthData.confidenceMap,
           CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) == kCVReturnSuccess,
           let confidenceBaseAddress = CVPixelBufferGetBaseAddress(confidenceMap) {
            lockedConfidenceMap = confidenceMap
            confidencePointer = confidenceBaseAddress.assumingMemoryBound(to: UInt8.self)
            confidenceBytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        }
        defer {
            if let confidenceMap = lockedConfidenceMap {
                CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly)
            }
        }

        let imageWidth = CVPixelBufferGetWidth(colorPixelBuffer)
        let imageHeight = CVPixelBufferGetHeight(colorPixelBuffer)
        let colorBytesPerRow = CVPixelBufferGetBytesPerRow(colorPixelBuffer)
        let depthRows = depthBytesPerRow / MemoryLayout<Float32>.size
        let depthBase = depthBaseAddress.assumingMemoryBound(to: Float32.self)
        let colorBase = colorBaseAddress.assumingMemoryBound(to: UInt8.self)

        let intrinsics = frame.camera.intrinsics
        let scaleX = Float(depthWidth) / Float(imageWidth)
        let scaleY = Float(depthHeight) / Float(imageHeight)
        let fx = max(intrinsics.columns.0.x * scaleX, 1)
        let fy = max(intrinsics.columns.1.y * scaleY, 1)
        let cx = intrinsics.columns.2.x * scaleX
        let cy = intrinsics.columns.2.y * scaleY
        let cameraTransform = frame.camera.transform
        let cameraRotationMatrix = simd_float3x3(
            SIMD3<Float>(cameraTransform.columns.0.x, cameraTransform.columns.0.y, cameraTransform.columns.0.z),
            SIMD3<Float>(cameraTransform.columns.1.x, cameraTransform.columns.1.y, cameraTransform.columns.1.z),
            SIMD3<Float>(cameraTransform.columns.2.x, cameraTransform.columns.2.y, cameraTransform.columns.2.z)
        )
        let cameraRotation = simd_quatf(cameraRotationMatrix).vector
        let sampleStride = max(2, max(depthWidth / 80, depthHeight / 60))
        let opacityLogit = Float(log(0.72 / (1.0 - 0.72)))

        for y in Swift.stride(from: 0, to: depthHeight, by: sampleStride) {
            if gaussianSeeds.count >= maximumSplats { break }
            for x in Swift.stride(from: 0, to: depthWidth, by: sampleStride) {
                if gaussianSeeds.count >= maximumSplats { break }
                if let confidencePointer {
                    let confidence = confidencePointer[y * confidenceBytesPerRow + x]
                    if confidence == 0 { continue }
                }

                let distance = depthBase[y * depthRows + x]
                guard distance.isFinite, distance >= 0.18, distance <= 5.5 else { continue }

                let colorX = min(imageWidth - 1, max(0, Int((Float(x) + 0.5) / Float(depthWidth) * Float(imageWidth))))
                let colorY = min(imageHeight - 1, max(0, Int((Float(y) + 0.5) / Float(depthHeight) * Float(imageHeight))))
                let colorOffset = colorY * colorBytesPerRow + colorX * 4
                let blue = Float(colorBase[colorOffset]) / 255
                let green = Float(colorBase[colorOffset + 1]) / 255
                let red = Float(colorBase[colorOffset + 2]) / 255

                // ARKit camera coordinates look along -Z; pixel rows increase downwards.
                let localPoint = SIMD4<Float>(
                    (Float(x) + 0.5 - cx) / fx * distance,
                    -(Float(y) + 0.5 - cy) / fy * distance,
                    -distance,
                    1
                )
                let worldPoint = cameraTransform * localPoint
                let worldScaleX = max(distance * Float(sampleStride) / fx * 0.55, 0.001)
                let worldScaleY = max(distance * Float(sampleStride) / fy * 0.55, 0.001)
                let worldScaleZ = max(distance * 0.006, 0.001)

                gaussianSeeds.append(
                    GaussianSeed(
                        x: worldPoint.x,
                        y: worldPoint.y,
                        z: worldPoint.z,
                        redDC: (red - 0.5) / sphericalHarmonicDC,
                        greenDC: (green - 0.5) / sphericalHarmonicDC,
                        blueDC: (blue - 0.5) / sphericalHarmonicDC,
                        opacityLogit: opacityLogit,
                        scaleX: log(worldScaleX),
                        scaleY: log(worldScaleY),
                        scaleZ: log(worldScaleZ),
                        rotationW: cameraRotation.w,
                        rotationX: cameraRotation.x,
                        rotationY: cameraRotation.y,
                        rotationZ: cameraRotation.z
                    )
                )
            }
        }

        let transform = cameraTransform
        let record: [String: Any] = [
            "index": nextFrameIndex,
            "timestamp": frame.timestamp,
            "image": imageURL.lastPathComponent,
            "depth": depthURL.lastPathComponent,
            "imageWidth": imageWidth,
            "imageHeight": imageHeight,
            "depthWidth": depthWidth,
            "depthHeight": depthHeight,
            "depthBytesPerRow": depthBytesPerRow,
            "cameraIntrinsics": [
                intrinsics.columns.0.x, intrinsics.columns.0.y, intrinsics.columns.0.z,
                intrinsics.columns.1.x, intrinsics.columns.1.y, intrinsics.columns.1.z,
                intrinsics.columns.2.x, intrinsics.columns.2.y, intrinsics.columns.2.z
            ],
            "cameraTransformColumnMajor": [
                transform.columns.0.x, transform.columns.0.y, transform.columns.0.z, transform.columns.0.w,
                transform.columns.1.x, transform.columns.1.y, transform.columns.1.z, transform.columns.1.w,
                transform.columns.2.x, transform.columns.2.y, transform.columns.2.z, transform.columns.2.w,
                transform.columns.3.x, transform.columns.3.y, transform.columns.3.z, transform.columns.3.w
            ]
        ]
        frameRecords.append(record)

        let frameInfoURL = folder.appendingPathComponent(frameName).appendingPathExtension("json")
        let frameInfo = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try frameInfo.write(to: frameInfoURL, options: .atomic)
    }

    private func makeColorBuffer(from image: CIImage) throws -> CVPixelBuffer {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        var output: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &output
        ) == kCVReturnSuccess, let output else {
            throw CaptureError.colorBufferUnavailable
        }
        ciContext.render(image, to: output, bounds: image.extent, colorSpace: colorSpace)
        return output
    }

    private func finishDataset() {
        guard let folder = sessionDirectory else {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.status = "没有可导出的采集数据"
            }
            return
        }

        do {
            let plyURL = folder.appendingPathComponent("gaussian_splats.ply")
            try writeGaussianPLY(to: plyURL)

            let manifest: [String: Any] = [
                "format": "DualCam LiDAR Gaussian Splat initial capture",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "frameCount": frameRecords.count,
                "gaussianSeedCount": gaussianSeeds.count,
                "depthSource": "ARKit sceneDepth / smoothedSceneDepth",
                "coordinateSystem": "ARKit world coordinates, meters",
                "plySchema": "x y z f_dc_0 f_dc_1 f_dc_2 opacity scale_0 scale_1 scale_2 rot_0 rot_1 rot_2 rot_3",
                "reconstructionStage": "depth-initialized Gaussian primitives; not trained or densified",
                "notes": "Captured RGB frames, raw Float32 depth maps, camera intrinsics and camera-to-world transforms are saved alongside the PLY.",
                "frames": frameRecords
            ]
            let manifestData = try JSONSerialization.data(
                withJSONObject: manifest,
                options: [.prettyPrinted, .sortedKeys]
            )
            try manifestData.write(to: folder.appendingPathComponent("session.json"), options: .atomic)

            DispatchQueue.main.async {
                self.plyURL = plyURL
                self.frameCount = self.frameRecords.count
                self.splatCount = self.gaussianSeeds.count
                self.isCapturing = false
                self.status = self.gaussianSeeds.isEmpty
                    ? "已结束，但没有获得有效深度点"
                    : "3D 初始场景已导出，可分享 Gaussian PLY"
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
                self.isCapturing = false
                self.status = "3D 文件导出失败"
            }
        }
    }

    private func writeGaussianPLY(to url: URL) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment DualCam ARKit LiDAR depth-initialised Gaussian primitives
        comment Initial splats only; optimisation and densification have not been run
        element vertex \(gaussianSeeds.count)
        property float x
        property float y
        property float z
        property float f_dc_0
        property float f_dc_1
        property float f_dc_2
        property float opacity
        property float scale_0
        property float scale_1
        property float scale_2
        property float rot_0
        property float rot_1
        property float rot_2
        property float rot_3
        end_header
        """

        var data = Data(header.utf8)
        data.reserveCapacity(data.count + gaussianSeeds.count * 14 * MemoryLayout<Float>.size)
        for point in gaussianSeeds {
            let values: [Float] = [
                point.x, point.y, point.z,
                point.redDC, point.greenDC, point.blueDC,
                point.opacityLogit,
                point.scaleX, point.scaleY, point.scaleZ,
                point.rotationW, point.rotationX, point.rotationY, point.rotationZ
            ]
            for value in values {
                appendLittleEndianFloat(value, to: &data)
            }
        }
        try data.write(to: url, options: .atomic)
    }

    private func appendLittleEndianFloat(_ value: Float, to data: inout Data) {
        var bits = value.bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }

    private enum CaptureError: LocalizedError {
        case captureFolderMissing
        case imageEncodingFailed
        case depthBufferUnavailable
        case colorBufferUnavailable

        var errorDescription: String? {
            switch self {
            case .captureFolderMissing: return "采集目录尚未创建。"
            case .imageEncodingFailed: return "彩色帧编码失败。"
            case .depthBufferUnavailable: return "无法读取 LiDAR 深度缓冲区。"
            case .colorBufferUnavailable: return "无法读取相机颜色帧。"
            }
        }
    }
}

private struct SpatialARPreview: UIViewRepresentable {
    let manager: SpatialLiveCaptureManager

    func makeUIView(context: Context) -> ARView {
        let view = ARView(
            frame: .zero,
            cameraMode: .ar,
            automaticallyConfigureSession: false
        )
        view.backgroundColor = .black
        manager.attach(session: view.session)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        // The manager attaches the session once; do not re-run AR tracking on SwiftUI updates.
    }
}

struct SpatialLiveCaptureView: View {
    @EnvironmentObject private var camera: CameraManager
    @Environment(\.dismiss) private var dismiss
    @StateObject private var capture = SpatialLiveCaptureManager()

    var body: some View {
        ZStack {
            SpatialARPreview(manager: capture)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.72), .clear, .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 18) {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .accessibilityLabel("关闭 3D 实况")

                    Spacer()

                    Label("3D 实况", systemImage: "cube.transparent")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    Color.clear.frame(width: 42, height: 42)
                }
                .padding(.top, 10)

                Spacer()

                VStack(spacing: 10) {
                    Text(capture.status)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 18) {
                        Label("\(capture.frameCount) 帧", systemImage: "camera")
                        Label("\(capture.splatCount.formatted()) 个 Gaussian", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                    Text("缓慢环绕对象移动，保持主体完整并避免快速抖动。采集会保存彩色帧、原始深度和相机位姿。")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.76))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if let error = capture.errorMessage {
                        Text(error)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        if capture.isCapturing {
                            capture.stopCapture()
                        } else {
                            capture.startCapture()
                        }
                    } label: {
                        Label(
                            capture.isCapturing ? "停止并生成 3D 场景" : "开始 3D 采集",
                            systemImage: capture.isCapturing ? "stop.fill" : "record.circle"
                        )
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background(capture.isCapturing ? Color.orange : Color.white, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!capture.isSupported && !capture.isCapturing)
                    .opacity(capture.isSupported || capture.isCapturing ? 1 : 0.45)

                    if let plyURL = capture.plyURL {
                        ShareLink(item: plyURL) {
                            Label("分享 Gaussian PLY", systemImage: "square.and.arrow.up")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }

                    Text("导出的是 LiDAR 深度初始化的 Gaussian 点元，可继续用于 3DGS 优化；当前版本尚未执行训练、稠密化或完整视角合成。")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.58))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .padding(.bottom, 18)
            }
            .padding(.horizontal, 16)
        }
        .background(Color.black)
        .statusBarHidden(true)
        .onAppear {
            camera.setLocalCameraCaptureSuspended(true) {
                capture.startSession()
            }
        }
        .onDisappear {
            capture.stopSession {
                camera.setLocalCameraCaptureSuspended(false)
            }
        }
    }
}
