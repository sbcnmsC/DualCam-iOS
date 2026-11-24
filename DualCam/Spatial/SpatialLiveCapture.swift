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
    @Published private(set) var surfaceSummary = "正在识别空间表面…"
    @Published private(set) var sampledMeshFaces = 0
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
    private var voxelIndices: [VoxelKey: Int] = [:]
    private var lastSampleTimestamp: TimeInterval = 0
    private var lastSurfaceUpdateTimestamp: TimeInterval = 0
    private var lastKeyframeTransform: simd_float4x4?
    private var nextFrameIndex = 0
    private var rawGaussianObservations = 0

    private let minimumFrameInterval: TimeInterval = 0.22
    private let maximumFrames = 96
    private let maximumSplats = 180_000
    private let voxelSize: Float = 0.018
    private let minimumTranslationForKeyframe: Float = 0.035
    private let minimumRotationForKeyframe: Float = 0.087
    private let sphericalHarmonicDC: Float = 0.28209479177387814

    private struct VoxelKey: Hashable {
        let x: Int32
        let y: Int32
        let z: Int32
    }

    private struct GaussianSeed {
        var x: Float
        var y: Float
        var z: Float
        var redDC: Float
        var greenDC: Float
        var blueDC: Float
        var opacityLogit: Float
        var scaleX: Float
        var scaleY: Float
        var scaleZ: Float
        var rotationW: Float
        var rotationX: Float
        var rotationY: Float
        var rotationZ: Float
        var sampleCount: Int

        mutating func fuse(_ other: GaussianSeed) {
            let nextCount = sampleCount + other.sampleCount
            let blend = Float(other.sampleCount) / Float(nextCount)
            let keep = 1 - blend

            x = x * keep + other.x * blend
            y = y * keep + other.y * blend
            z = z * keep + other.z * blend
            redDC = redDC * keep + other.redDC * blend
            greenDC = greenDC * keep + other.greenDC * blend
            blueDC = blueDC * keep + other.blueDC * blend
            opacityLogit = opacityLogit * keep + other.opacityLogit * blend
            scaleX = scaleX * keep + other.scaleX * blend
            scaleY = scaleY * keep + other.scaleY * blend
            scaleZ = scaleZ * keep + other.scaleZ * blend

            let current = simd_quatf(ix: rotationX, iy: rotationY, iz: rotationZ, r: rotationW)
            let incoming = simd_quatf(ix: other.rotationX, iy: other.rotationY,
                                      iz: other.rotationZ, r: other.rotationW)
            let alignedIncoming = simd_dot(current.vector, incoming.vector) < 0
                ? simd_quatf(vector: -incoming.vector) : incoming
            let merged = simd_slerp(current, alignedIncoming, blend)
            rotationW = merged.vector.w
            rotationX = merged.vector.x
            rotationY = merged.vector.y
            rotationZ = merged.vector.z
            sampleCount = nextCount
        }
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

    /// Release camera and rendering work while the Metal Gaussian viewer is on top.
    func pauseSpatialSessionForViewer() {
        arSession?.pause()
        captureQueue.async { self.stopFramePolling() }
    }

    func resumeSpatialSessionAfterViewer() {
        guard startRequested, let session = arSession else { return }
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
        configuration.planeDetection = [.horizontal, .vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }
        isSupported = true
        errorMessage = nil
        status = "LiDAR 网格与深度已就绪，环绕主体扫描"
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        captureQueue.async { self.startFramePollingIfNeeded() }
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
                let imagesFolder = folder.appendingPathComponent("images", isDirectory: true)
                try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)

                self.sessionDirectory = folder
                self.frameRecords.removeAll(keepingCapacity: true)
                self.gaussianSeeds.removeAll(keepingCapacity: true)
                self.voxelIndices.removeAll(keepingCapacity: true)
                self.lastSampleTimestamp = 0
                self.lastSurfaceUpdateTimestamp = 0
                self.lastKeyframeTransform = nil
                self.nextFrameIndex = 0
                self.rawGaussianObservations = 0
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
        guard let frame = arSession?.currentFrame else { return }
        updateSurfaceRecognition(from: frame)

        guard isCapturingOnQueue,
              case .normal = frame.camera.trackingState,
              frame.timestamp - lastSampleTimestamp >= minimumFrameInterval,
              isUsefulKeyframe(frame) else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        guard nextFrameIndex < maximumFrames, gaussianSeeds.count < maximumSplats else {
            isCapturingOnQueue = false
            finishDataset()
            return
        }

        do {
            try appendFrame(frame, depthData: depthData)
            lastSampleTimestamp = frame.timestamp
            lastKeyframeTransform = frame.camera.transform
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
                    self.status = "采集中 · \(currentFrames)/\(self.maximumFrames) 帧"
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

    /// Sample ARKit's classified scene mesh separately from Gaussian keyframes.
    /// This reports architectural surface classes, not arbitrary object detection.
    private func updateSurfaceRecognition(from frame: ARFrame) {
        guard frame.timestamp - lastSurfaceUpdateTimestamp >= 1.0 else { return }
        lastSurfaceUpdateTimestamp = frame.timestamp

        var counts: [String: Int] = [:]
        var sampledFaces = 0

        for anchor in frame.anchors.compactMap({ $0 as? ARMeshAnchor }) {
            let geometry = anchor.geometry
            guard let classifications = geometry.classification else { continue }
            let faceCount = min(geometry.faces.count, classifications.count)
            guard faceCount > 0 else { continue }
            let sampleStep = max(1, faceCount / 1_500)

            for faceIndex in Swift.stride(from: 0, to: faceCount, by: sampleStep) {
                sampledFaces += 1
                let classificationAddress = classifications.buffer.contents()
                    .advanced(by: classifications.offset + faceIndex * classifications.stride)
                let rawClassification = Int(classificationAddress.assumingMemoryBound(to: UInt8.self).pointee)
                let classification = ARMeshClassification(rawValue: rawClassification) ?? .none
                let label: String
                switch classification {
                case .floor: label = "地面"
                case .wall: label = "墙面"
                case .ceiling: label = "天花板"
                case .table: label = "桌面"
                case .seat: label = "座椅"
                case .window: label = "窗户"
                case .door: label = "门"
                case .none: continue
                @unknown default: label = "其他表面"
                }
                counts[label, default: 0] += 1
            }
        }

        let summary = counts
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map { "\($0.key) \($0.value)" }
            .joined(separator: " · ")
        DispatchQueue.main.async {
            self.sampledMeshFaces = sampledFaces
            self.surfaceSummary = summary.isEmpty ? "已建立场景网格，正在识别表面…" : summary
        }
    }

    /// Keep frames only when the camera has materially changed pose, reducing near-duplicate
    /// RGB/depth keyframes before the later world-space fusion pass.
    private func isUsefulKeyframe(_ frame: ARFrame) -> Bool {
        guard let previous = lastKeyframeTransform else { return true }
        let current = frame.camera.transform
        let previousPosition = SIMD3<Float>(previous.columns.3.x, previous.columns.3.y, previous.columns.3.z)
        let currentPosition = SIMD3<Float>(current.columns.3.x, current.columns.3.y, current.columns.3.z)
        let translation = simd_distance(previousPosition, currentPosition)

        let previousForward = simd_normalize(SIMD3<Float>(
            -previous.columns.2.x, -previous.columns.2.y, -previous.columns.2.z
        ))
        let currentForward = simd_normalize(SIMD3<Float>(
            -current.columns.2.x, -current.columns.2.y, -current.columns.2.z
        ))
        let cosine = min(max(simd_dot(previousForward, currentForward), -1), 1)
        let rotation = acos(cosine)
        return translation >= minimumTranslationForKeyframe || rotation >= minimumRotationForKeyframe
    }

    private func voxelKey(for point: SIMD3<Float>) -> VoxelKey {
        VoxelKey(
            x: Int32(floor(point.x / voxelSize)),
            y: Int32(floor(point.y / voxelSize)),
            z: Int32(floor(point.z / voxelSize))
        )
    }

    private func appendOrFuse(_ candidate: GaussianSeed) {
        rawGaussianObservations += 1
        let key = voxelKey(for: SIMD3<Float>(candidate.x, candidate.y, candidate.z))
        if let index = voxelIndices[key], gaussianSeeds.indices.contains(index) {
            gaussianSeeds[index].fuse(candidate)
        } else if gaussianSeeds.count < maximumSplats {
            voxelIndices[key] = gaussianSeeds.count
            gaussianSeeds.append(candidate)
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
        let imagesFolder = folder.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        let imageURL = imagesFolder.appendingPathComponent(frameName).appendingPathExtension("jpg")
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
        let sampleStride = max(2, max(depthWidth / 80, depthHeight / 60))
        let opacityLogit = Float(log(0.72 / (1.0 - 0.72)))

        for y in Swift.stride(from: 0, to: depthHeight, by: sampleStride) {
            if gaussianSeeds.count >= maximumSplats { break }
            for x in Swift.stride(from: 0, to: depthWidth, by: sampleStride) {
                if gaussianSeeds.count >= maximumSplats { break }
                if let confidencePointer {
                    let confidence = confidencePointer[y * confidenceBytesPerRow + x]
                    // ARKit confidence: 0 low, 1 medium, 2 high.
                    if confidence < 1 { continue }
                }

                let distance = depthBase[y * depthRows + x]
                guard distance.isFinite, distance >= 0.18, distance <= 5.5 else { continue }

                // Reject depth discontinuities that commonly create flying pixels at silhouettes.
                let rightX = min(depthWidth - 1, x + sampleStride)
                let downY = min(depthHeight - 1, y + sampleStride)
                let rightDepth = depthBase[y * depthRows + rightX]
                let downDepth = depthBase[downY * depthRows + x]
                let edgeThreshold = max(0.05, distance * 0.045)
                guard rightDepth.isFinite, downDepth.isFinite,
                      rightDepth >= 0.18, downDepth >= 0.18,
                      abs(rightDepth - distance) <= edgeThreshold,
                      abs(downDepth - distance) <= edgeThreshold else { continue }

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
                let center = SIMD3<Float>(worldPoint.x, worldPoint.y, worldPoint.z)

                let localRight = SIMD4<Float>(
                    (Float(rightX) + 0.5 - cx) / fx * rightDepth,
                    -(Float(y) + 0.5 - cy) / fy * rightDepth,
                    -rightDepth,
                    1
                )
                let localDown = SIMD4<Float>(
                    (Float(x) + 0.5 - cx) / fx * downDepth,
                    -(Float(downY) + 0.5 - cy) / fy * downDepth,
                    -downDepth,
                    1
                )
                let worldRight4 = cameraTransform * localRight
                let worldDown4 = cameraTransform * localDown
                let tangentX = SIMD3<Float>(worldRight4.x, worldRight4.y, worldRight4.z) - center
                let tangentY = SIMD3<Float>(worldDown4.x, worldDown4.y, worldDown4.z) - center

                var gaussianRotation = simd_quatf(cameraRotationMatrix)
                let worldScaleX = max(simd_length(tangentX) * 0.55, 0.001)
                let worldScaleY = max(simd_length(tangentY) * 0.55, 0.001)
                if simd_length(tangentX) > 0.0001 && simd_length(tangentY) > 0.0001 {
                    let axisX = simd_normalize(tangentX)
                    let yCandidate = simd_normalize(tangentY)
                    let orthogonalY = simd_normalize(yCandidate - axisX * simd_dot(axisX, yCandidate))
                    let normal = simd_normalize(simd_cross(axisX, orthogonalY))
                    if normal.x.isFinite && normal.y.isFinite && normal.z.isFinite {
                        gaussianRotation = simd_quatf(simd_float3x3(axisX, orthogonalY, normal))
                    }
                }
                let worldScaleZ = max(distance * 0.003, 0.001)

                appendOrFuse(
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
                        rotationW: gaussianRotation.vector.w,
                        rotationX: gaussianRotation.vector.x,
                        rotationY: gaussianRotation.vector.y,
                        rotationZ: gaussianRotation.vector.z,
                        sampleCount: 1
                    )
                )
            }
        }

        let transform = cameraTransform
        let record: [String: Any] = [
            "index": nextFrameIndex,
            "timestamp": frame.timestamp,
            "image": "images/\(imageURL.lastPathComponent)",
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
            guard frameRecords.count >= 6, gaussianSeeds.count >= 100 else {
                throw CaptureError.insufficientSceneData
            }
            DispatchQueue.main.async {
                self.status = "正在融合多视角深度点并整理 Gaussian…"
            }
            let plyURL = folder.appendingPathComponent("gaussian_splats.ply")
            try writeGaussianPLY(to: plyURL)
            try writeInitialPointCloudPLY(to: folder.appendingPathComponent("points3D.ply"))
            try writeNerfstudioTransforms(to: folder)
            let bounds = sceneBounds()

            let manifest: [String: Any] = [
                "format": "DualCam LiDAR multi-view fused Gaussian Splat scene",
                "createdAt": ISO8601DateFormatter().string(from: Date()),
                "frameCount": frameRecords.count,
                "gaussianSeedCount": gaussianSeeds.count,
                "rawDepthObservations": rawGaussianObservations,
                "fusedVoxelCount": gaussianSeeds.count,
                "voxelSizeMeters": voxelSize,
                "keyframePolicy": "retain frame after 0.035m translation or 0.087rad view rotation",
                "depthSource": "ARKit sceneDepth / smoothedSceneDepth",
                "coordinateSystem": "ARKit world coordinates, meters",
                "sceneBounds": [
                    "min": [bounds.minimum.x, bounds.minimum.y, bounds.minimum.z],
                    "max": [bounds.maximum.x, bounds.maximum.y, bounds.maximum.z]
                ],
                "plySchema": "x y z f_dc_0 f_dc_1 f_dc_2 opacity scale_0 scale_1 scale_2 rot_0 rot_1 rot_2 rot_3",
                "reconstructionStage": "ARKit LiDAR depth fusion initialisation; Nerfstudio camera dataset exported for on-device photometric 3DGS training",
                "notes": "Captured RGB frames, raw Float32 depth maps, camera intrinsics and camera-to-world transforms are saved alongside the fused PLY.",
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
                    : "多视角融合完成，可预览 3D Gaussian 场景"
            }
        } catch {
            DispatchQueue.main.async {
                self.errorMessage = error.localizedDescription
                self.isCapturing = false
                self.status = "3D 文件导出失败"
            }
        }
    }

    /// Export the RGB frames, calibrated intrinsics, and camera-to-world poses in
    /// Nerfstudio's transforms.json schema consumed by msplat's GaussianDataset.
    /// msplat's Nerfstudio loader uses points3D.ply as the initial xyz/RGB cloud.
    /// Keep this separate from the GraphDECO Gaussian PLY exported for the viewer.
    private func writeInitialPointCloudPLY(to url: URL) throws {
        let header = """
        ply
        format binary_little_endian 1.0
        comment DualCam ARKit LiDAR coloured point cloud for msplat initialisation
        element vertex \(gaussianSeeds.count)
        property float x
        property float y
        property float z
        property uchar red
        property uchar green
        property uchar blue
        end_header
        """
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + gaussianSeeds.count * 15)

        for point in gaussianSeeds {
            appendLittleEndianFloat(point.x, to: &data)
            appendLittleEndianFloat(point.y, to: &data)
            appendLittleEndianFloat(point.z, to: &data)
            let red = UInt8((min(max(point.redDC * sphericalHarmonicDC + 0.5, 0), 1) * 255).rounded())
            let green = UInt8((min(max(point.greenDC * sphericalHarmonicDC + 0.5, 0), 1) * 255).rounded())
            let blue = UInt8((min(max(point.blueDC * sphericalHarmonicDC + 0.5, 0), 1) * 255).rounded())
            data.append(contentsOf: [red, green, blue])
        }

        try data.write(to: url, options: .atomic)
    }

    private func writeNerfstudioTransforms(to folder: URL) throws {
        guard let first = frameRecords.first,
              let intrinsics = first["cameraIntrinsics"] as? [NSNumber],
              intrinsics.count >= 9,
              let width = first["imageWidth"] as? Int,
              let height = first["imageHeight"] as? Int else {
            throw CaptureError.transformsExportFailed
        }

        var frames: [[String: Any]] = []
        frames.reserveCapacity(frameRecords.count)
        for record in frameRecords {
            guard let imagePath = record["image"] as? String,
                  let matrix = record["cameraTransformColumnMajor"] as? [NSNumber],
                  matrix.count == 16 else { continue }

            let transformMatrix: [[Float]] = [
                [matrix[0].floatValue, matrix[4].floatValue, matrix[8].floatValue, matrix[12].floatValue],
                [matrix[1].floatValue, matrix[5].floatValue, matrix[9].floatValue, matrix[13].floatValue],
                [matrix[2].floatValue, matrix[6].floatValue, matrix[10].floatValue, matrix[14].floatValue],
                [matrix[3].floatValue, matrix[7].floatValue, matrix[11].floatValue, matrix[15].floatValue]
            ]
            frames.append([
                "file_path": imagePath,
                "transform_matrix": transformMatrix
            ])
        }

        guard frames.count >= 5 else { throw CaptureError.transformsExportFailed }
        let document: [String: Any] = [
            "camera_model": "OPENCV",
            "ply_file_path": "points3D.ply",
            "fl_x": intrinsics[0].doubleValue,
            "fl_y": intrinsics[4].doubleValue,
            "cx": intrinsics[6].doubleValue,
            "cy": intrinsics[7].doubleValue,
            "w": width,
            "h": height,
            "k1": 0.0,
            "k2": 0.0,
            "p1": 0.0,
            "p2": 0.0,
            "frames": frames
        ]
        let data = try JSONSerialization.data(
            withJSONObject: document,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: folder.appendingPathComponent("transforms.json"), options: .atomic)
    }

    private func sceneBounds() -> (minimum: SIMD3<Float>, maximum: SIMD3<Float>) {
        guard let first = gaussianSeeds.first else { return (.zero, .zero) }
        var minimum = SIMD3<Float>(first.x, first.y, first.z)
        var maximum = minimum
        for point in gaussianSeeds.dropFirst() {
            minimum = simd_min(minimum, SIMD3<Float>(point.x, point.y, point.z))
            maximum = simd_max(maximum, SIMD3<Float>(point.x, point.y, point.z))
        }
        return (minimum, maximum)
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
        case transformsExportFailed
        case insufficientSceneData

        var errorDescription: String? {
            switch self {
            case .captureFolderMissing: return "采集目录尚未创建。"
            case .imageEncodingFailed: return "彩色帧编码失败。"
            case .depthBufferUnavailable: return "无法读取 LiDAR 深度缓冲区。"
            case .colorBufferUnavailable: return "无法读取相机颜色帧。"
            case .transformsExportFailed: return "无法生成训练相机数据，请重新扫描并至少保留 6 个有效视角。"
            case .insufficientSceneData: return "有效空间数据不足：至少需要 6 个有效视角和 100 个 LiDAR 点，请增加扫描覆盖。"
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
        view.debugOptions.insert(.showSceneUnderstanding)
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
    @StateObject private var training = GaussianTrainingManager()
    @State private var showGaussianViewer = false
    @State private var selectedViewerURL: URL?
    @State private var isClosingCapture = false

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
                    .disabled(training.isWorking)

                    Spacer()

                    Label("3D 实况 · LiDAR", systemImage: "cube.transparent")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)

                    Spacer()

                    Color.clear.frame(width: 42, height: 42)
                }
                .padding(.top, 10)

                Spacer()

                ScrollView(.vertical) {
                    VStack(spacing: 10) {
                    Text(capture.status)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 18) {
                        Label("\(capture.frameCount) 视角", systemImage: "camera")
                        Label("\(capture.splatCount.formatted()) 个初始点", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                    Text("空间分类 · \(capture.surfaceSummary)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.cyan.opacity(0.95))
                        .multilineTextAlignment(.center)

                    Text("保持主体始终在画面内，缓慢绕行一圈，再从略高和略低角度补拍。网格用于显示空间表面；训练使用彩色帧、相机内参与位姿。")
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

                    if let initialPLY = capture.plyURL {
                        VStack(spacing: 10) {
                            Picker("训练步数", selection: $training.iterationTarget) {
                                Text("快速 1K").tag(1_000)
                                Text("均衡 2K").tag(2_000)
                                Text("高质量 4K").tag(4_000)
                            }
                            .pickerStyle(.segmented)
                            .disabled(training.isWorking)

                            Button {
                                if training.isWorking {
                                    training.cancelTraining()
                                } else {
                                    capture.pauseSpatialSessionForViewer()
                                    training.startTraining(datasetURL: initialPLY.deletingLastPathComponent())
                                    if !training.isWorking {
                                        capture.resumeSpatialSessionAfterViewer()
                                    }
                                }
                            } label: {
                                Label(
                                    training.isWorking ? "停止训练" : "开始真正的 3DGS 训练",
                                    systemImage: training.isWorking ? "stop.fill" : "cpu"
                                )
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(training.isWorking ? Color.orange : Color.white, in: Capsule())
                            }
                            .disabled(training.phase == .loading || capture.frameCount < 6 || capture.splatCount < 100)

                            if training.isWorking {
                                ProgressView(value: training.progress)
                                    .tint(.cyan)
                                HStack {
                                    Text("\(training.iteration) / \(training.totalIterations) 步")
                                    Spacer()
                                    Text("\(training.availableMemoryMB) MB 可用")
                                }
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.7))
                            }

                            if let preview = training.previewImage {
                                Image(uiImage: preview)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 112)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }

                            Text(training.status)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.76))
                                .multilineTextAlignment(.center)

                            Button {
                                selectedViewerURL = training.exportedPLY ?? initialPLY
                                capture.pauseSpatialSessionForViewer()
                                showGaussianViewer = true
                            } label: {
                                Label(
                                    training.exportedPLY == nil ? "预览 LiDAR 初始场景" : "预览训练后的 3D 场景",
                                    systemImage: "cube.transparent"
                                )
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.black)
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                                .background(Color.white, in: Capsule())
                            }

                            if let outputPLY = training.exportedPLY {
                                ShareLink(item: outputPLY) {
                                    Label("导出训练 PLY", systemImage: "square.and.arrow.up")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            if let outputSPZ = training.exportedSPZ {
                                ShareLink(item: outputSPZ) {
                                    Label("导出压缩 SPZ", systemImage: "shippingbox")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                }
                            }
                            ShareLink(item: initialPLY) {
                                Label("分享 LiDAR 初始 PLY", systemImage: "point.3.connected.trianglepath.dotted")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(18)
            .frame(maxHeight: 560)
            .scrollIndicators(.hidden)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .padding(.bottom, 18)
            }
            .padding(.horizontal, 16)
        }
        .background(Color.black)
        .statusBarHidden(true)
        .interactiveDismissDisabled(training.isWorking)
        .sheet(
            isPresented: $showGaussianViewer,
            onDismiss: { capture.resumeSpatialSessionAfterViewer() }
        ) {
            if let url = selectedViewerURL {
                GaussianSplatViewerScreen(url: url)
            }
        }
        .onChange(of: training.phase) { oldPhase, newPhase in
            let wasWorking = oldPhase == .loading || oldPhase == .training
            let isWorking = newPhase == .loading || newPhase == .training
            if wasWorking && !isWorking && !isClosingCapture {
                capture.resumeSpatialSessionAfterViewer()
            }
        }
        .onAppear {
            camera.setLocalCameraCaptureSuspended(true) {
                capture.startSession()
            }
        }
        .onDisappear {
            if training.isWorking {
                isClosingCapture = true
                training.onTrainingFinished = {
                    capture.stopSession {
                        camera.setLocalCameraCaptureSuspended(false)
                    }
                }
                training.cancelTraining()
            } else {
                capture.stopSession {
                    camera.setLocalCameraCaptureSuspended(false)
                }
            }
        }
    }
}
