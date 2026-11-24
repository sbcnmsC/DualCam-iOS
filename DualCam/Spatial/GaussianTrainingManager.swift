import CoreGraphics
import Darwin
import Foundation
import Msplat
import SwiftUI
import os
import UIKit

/// On-device 3DGS training over a Nerfstudio transforms.json capture.
final class GaussianTrainingManager: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case training
        case finished
        case cancelled
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var iteration = 0
    @Published private(set) var totalIterations = 2_000
    @Published private(set) var splatCount = 0
    @Published private(set) var millisecondsPerStep: Float = 0
    @Published private(set) var availableMemoryMB = 0
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var exportedPLY: URL?
    @Published private(set) var previewPLY: URL?
    @Published private(set) var exportedSPZ: URL?
    @Published private(set) var status = "等待 LiDAR 采集数据"

    /// 1K is useful for a quick pipeline check; 2K is the balanced default.
    @Published var iterationTarget = 2_000
    var onTrainingFinished: (() -> Void)?

    private let cancelFlag = CancellationFlag()
    private var worker: Thread?

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func reset() {
            lock.lock()
            cancelled = false
            lock.unlock()
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    var isWorking: Bool {
        phase == .loading || phase == .training
    }

    var progress: Double {
        guard totalIterations > 0 else { return 0 }
        return min(Double(iteration) / Double(totalIterations), 1)
    }

    func startTraining(datasetURL: URL) {
        guard !isWorking else { return }
        cancelFlag.reset()
        iteration = 0
        splatCount = 0
        millisecondsPerStep = 0
        availableMemoryMB = Self.availableMemoryInMB()
        previewImage = nil
        exportedPLY = nil
        previewPLY = nil
        exportedSPZ = nil
        totalIterations = max(500, min(iterationTarget, 4_000))
        guard availableMemoryMB >= 1_200 else {
            phase = .failed(TrainingError.lowMemory.localizedDescription)
            status = TrainingError.lowMemory.localizedDescription
            return
        }
        guard ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else {
            phase = .failed(TrainingError.thermal.localizedDescription)
            status = TrainingError.thermal.localizedDescription
            return
        }
        phase = .loading
        status = "正在检查相机数据集…"

        let path = datasetURL.path
        let steps = totalIterations
        let thread = Thread { [weak self] in
            self?.runTraining(path: path, iterations: steps)
        }
        thread.name = "com.dualcam.gaussian-training"
        thread.stackSize = 4 << 20
        worker = thread
        thread.start()
    }

    func cancelTraining() {
        cancelFlag.cancel()
        status = "正在安全停止训练…"
    }

    private func runTraining(path: String, iterations: Int) {
        autoreleasepool {
            do {
                let root = URL(fileURLWithPath: path, isDirectory: true)
                let transformsURL = root.appendingPathComponent("transforms.json")
                let transformsData = try Data(contentsOf: transformsURL)
                guard let document = try JSONSerialization.jsonObject(with: transformsData) as? [String: Any],
                      let frames = document["frames"] as? [[String: Any]],
                      frames.count >= 6 else {
                    throw TrainingError.insufficientViews
                }

                let pointCloudURL = root.appendingPathComponent("points3D.ply")
                let pointCloudAttributes = try? FileManager.default.attributesOfItem(atPath: pointCloudURL.path)
                let pointCloudSize = (pointCloudAttributes?[.size] as? NSNumber)?.intValue ?? 0
                guard pointCloudSize > 128 else { throw TrainingError.datasetAssetsMissing }

                for frame in frames {
                    guard let relativePath = frame["file_path"] as? String, !relativePath.isEmpty else {
                        throw TrainingError.datasetAssetsMissing
                    }
                    let imageURL = root.appendingPathComponent(relativePath)
                    guard FileManager.default.fileExists(atPath: imageURL.path) else {
                        throw TrainingError.datasetAssetsMissing
                    }
                }

                // msplat otherwise defaults to a 512 MB decoded-image LRU on iOS.
                // Keep headroom for DualCam's UI and the Metal renderer during training.
                setenv("MSPLAT_IMAGE_CACHE_MB", "384", 1)
                let dataset = GaussianDataset(path: path, downscaleFactor: 2.0)
                guard dataset.numTrain >= 5 else {
                    throw TrainingError.datasetLoadFailed
                }

                withExtendedLifetime(dataset) {
                    performTraining(
                        dataset: dataset,
                        outputDirectory: root,
                        iterations: iterations
                    )
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.phase = .failed(message)
                    self.status = message
                    self.worker = nil
                    let completion = self.onTrainingFinished
                    self.onTrainingFinished = nil
                    completion?()
                }
            }
        }
    }

    private func performTraining(
        dataset: GaussianDataset,
        outputDirectory: URL,
        iterations: Int
    ) {
        var config = TrainingConfig()
        config.iterations = Int32(iterations)
        config.downscaleFactor = 2.0
        config.numDownscales = 2
        config.resolutionSchedule = Int32(max(iterations / 3, 100))
        config.warmupLength = 200
        config.resetAlphaEvery = 3
        // MetalSplatter's PLY reader expects all 45 f_rest coefficients when SH is present.
        // Degree 3 emits exactly 45 and preserves the trained scene's view-dependent colour.
        config.shDegree = 3
        config.shDegreeInterval = Int32(max(iterations / 4, 100))
        config.stopDensifyAt = Int32(iterations * 2 / 3)
        // Keep the trained PLY/SPZ in the original ARKit world coordinate system.
        // The Metal viewer uses the capture manifest's original scene bounds.
        config.keepCrs = true
        config.bgColor = (0.015, 0.015, 0.015)

        let trainer = GaussianTrainer(dataset: dataset, config: config)
        guard trainer.splatCount > 0 else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.phase = .failed(TrainingError.emptyInitialization.localizedDescription)
                self.status = TrainingError.emptyInitialization.localizedDescription
                self.worker = nil
                let completion = self.onTrainingFinished
                self.onTrainingFinished = nil
                completion?()
            }
            return
        }

        let initialSplatCount = trainer.splatCount
        DispatchQueue.main.async { [weak self] in
            self?.phase = .training
            self?.status = "正在执行多视角 Gaussian 优化…"
            self?.splatCount = initialSplatCount
        }

        let previewInterval = max(iterations / 32, 40)
        var stopReason: String?

        for step in 0..<iterations {
            if cancelFlag.isCancelled {
                stopReason = "已由用户停止，正在导出当前训练结果…"
                break
            }

            // Keep a memory reserve for the camera UI, Metal renderer, and iOS.
            if step % 20 == 0 {
                let freeMemory = Self.availableMemoryInMB()
                if freeMemory > 0 && freeMemory < 384 {
                    stopReason = "可用内存不足，已提前停止并导出当前结果"
                    cancelFlag.cancel()
                    break
                }
                if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                    stopReason = "设备温度进入高温状态，已停止训练并导出当前结果"
                    cancelFlag.cancel()
                    break
                }
            }

            let stats = trainer.step()
            if step % previewInterval == 0 || step == iterations - 1 {
                let image = Self.image(from: trainer.render(cameraIndex: 0))
                let freeMemory = Self.availableMemoryInMB()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.iteration = stats.iteration
                    self.splatCount = stats.splatCount
                    self.millisecondsPerStep = stats.msPerStep
                    self.availableMemoryMB = freeMemory
                    self.previewImage = image
                    self.status = "训练中 · 第 \(stats.iteration) 步"
                }
            }
        }

        // Preserve the trainer's standard GraphDECO-compatible PLY for export.
        // MetalSplatter consumes interleaved SH triples, so build a separate preview copy.
        let plyURL = outputDirectory.appendingPathComponent("trained_gaussian_splats.ply")
        let previewPLYURL = outputDirectory.appendingPathComponent("trained_gaussian_splats_metalsplatter.ply")
        let spzURL = outputDirectory.appendingPathComponent("trained_gaussian_splats.spz")
        try? FileManager.default.removeItem(at: plyURL)
        try? FileManager.default.removeItem(at: previewPLYURL)
        try? FileManager.default.removeItem(at: spzURL)
        trainer.exportPly(to: plyURL.path)
        trainer.exportSpz(to: spzURL.path)

        let hasPLY = Self.isCompatibleGaussianPLY(plyURL)
        let hasPreviewPLY = hasPLY && Self.createMetalSplatterPreviewPLY(from: plyURL, to: previewPLYURL)
        let hasSPZ = FileManager.default.fileExists(atPath: spzURL.path)
        let wasCancelled = cancelFlag.isCancelled
        let finalIteration = trainer.iteration
        let finalSplatCount = trainer.splatCount

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.iteration = finalIteration
            self.splatCount = finalSplatCount
            self.exportedPLY = hasPLY ? plyURL : nil
            self.previewPLY = hasPreviewPLY ? previewPLYURL : nil
            self.exportedSPZ = hasSPZ ? spzURL : nil
            if hasPLY && hasPreviewPLY {
                self.phase = wasCancelled ? .cancelled : .finished
                self.status = stopReason ?? "训练完成 · 已导出优化后的 Gaussian 场景"
            } else if hasPLY {
                self.phase = .failed("训练 PLY 已导出，但 MetalSplatter 预览副本生成失败")
                self.status = "原始 PLY 已保留，预览副本转换失败"
            } else {
                self.phase = .failed("训练器导出的 PLY 不符合完整 SH3 格式")
                self.status = "训练 PLY 格式校验失败"
            }
            self.worker = nil
            let completion = self.onTrainingFinished
            self.onTrainingFinished = nil
            completion?()
        }
    }

    /// Validate the trainer's canonical GraphDECO-compatible SH3 PLY header.
    private static func isCompatibleGaussianPLY(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 65_536),
              let marker = data.range(of: Data("end_header\n".utf8)),
              let header = String(data: Data(data[..<marker.upperBound]), encoding: .utf8) else {
            return false
        }
        let lines = header.split(whereSeparator: \.isNewline).map(String.init)
        let required = [
            "ply", "format binary_little_endian 1.0",
            "property float x", "property float y", "property float z",
            "property float nx", "property float ny", "property float nz",
            "property float f_dc_0", "property float f_dc_1", "property float f_dc_2",
            "property float opacity", "property float scale_0", "property float scale_1", "property float scale_2",
            "property float rot_0", "property float rot_1", "property float rot_2", "property float rot_3"
        ] + (0..<45).map { "property float f_rest_\($0)" }
        return lines.contains(where: { $0.hasPrefix("element vertex ") })
            && required.allSatisfy { lines.contains($0) }
    }

    /// Convert channel-major GraphDECO SH values to MetalSplatter's interleaved RGB triples
    /// in a second file. Stream 256 vertices at a time to avoid loading the whole model in RAM.
    private static func createMetalSplatterPreviewPLY(from sourceURL: URL, to destinationURL: URL) -> Bool {
        let manager = FileManager.default
        let temporaryURL = destinationURL.appendingPathExtension("tmp")
        let rowBytes = 62 * MemoryLayout<Float>.size
        let shOffset = 9 * MemoryLayout<Float>.size
        let shBytes = 45 * MemoryLayout<Float>.size
        let rowsPerChunk = 256

        do {
            guard let input = try? FileHandle(forReadingFrom: sourceURL) else { return false }
            defer { try? input.close() }
            guard let prefix = try input.read(upToCount: 65_536),
                  let marker = prefix.range(of: Data("end_header\n".utf8)) else {
                return false
            }
            let headerData = Data(prefix[..<marker.upperBound])
            guard let header = String(data: headerData, encoding: .utf8),
                  let vertexLine = header.split(whereSeparator: \.isNewline)
                    .first(where: { $0.hasPrefix("element vertex ") }),
                  let vertexCount = Int(vertexLine.dropFirst("element vertex ".count)),
                  vertexCount > 0 else {
                return false
            }

            let attributes = try manager.attributesOfItem(atPath: sourceURL.path)
            let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard fileSize == headerData.count + vertexCount * rowBytes else { return false }

            try? manager.removeItem(at: temporaryURL)
            try? manager.removeItem(at: destinationURL)
            guard manager.createFile(atPath: temporaryURL.path, contents: nil) else {
                return false
            }
            do {
                guard let output = try? FileHandle(forWritingTo: temporaryURL) else {
                    try? manager.removeItem(at: temporaryURL)
                    return false
                }
                defer { try? output.close() }

                try output.write(contentsOf: headerData)
            try input.seek(toOffset: UInt64(headerData.count))

            var remaining = vertexCount
            var shScratch = [UInt8](repeating: 0, count: shBytes)

            while remaining > 0 {
                let rowCount = min(rowsPerChunk, remaining)
                let byteCount = rowCount * rowBytes
                guard var chunk = try input.read(upToCount: byteCount),
                      chunk.count == byteCount else {
                    throw TrainingFileError.unexpectedPLYLength
                }

                chunk.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
                    let bytes = raw.bindMemory(to: UInt8.self)
                    for row in 0..<rowCount {
                        let rowBase = row * rowBytes
                        let sourceBase = rowBase + shOffset
                        for index in 0..<shBytes {
                            shScratch[index] = bytes[sourceBase + index]
                        }
                        for basis in 0..<15 {
                            for channel in 0..<3 {
                                let sourceIndex = (channel * 15 + basis) * 4
                                let destinationIndex = (basis * 3 + channel) * 4
                                for byte in 0..<4 {
                                    bytes[sourceBase + destinationIndex + byte] = shScratch[sourceIndex + byte]
                                }
                            }
                        }
                    }
                }
                try output.write(contentsOf: chunk)
                remaining -= rowCount
            }

                try output.synchronize()
            }

            try manager.moveItem(at: temporaryURL, to: destinationURL)
            return manager.fileExists(atPath: destinationURL.path)
        } catch {
            try? manager.removeItem(at: temporaryURL)
            return false
        }
    }

    private enum TrainingFileError: Error {
        case unexpectedPLYLength
    }

    private static func availableMemoryInMB() -> Int {
        Int(os_proc_available_memory() / (1024 * 1024))
    }

    private static func image(from pixels: PixelData) -> UIImage? {
        let width = pixels.width
        let height = pixels.height
        let count = width * height
        guard width > 0, height > 0, pixels.pixels.count >= count * 3 else { return nil }

        var rgba = [UInt8](repeating: 255, count: count * 4)
        for index in 0..<count {
            for channel in 0..<3 {
                let value = pixels.pixels[index * 3 + channel]
                rgba[index * 4 + channel] = UInt8(min(max(value, 0), 1) * 255)
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private enum TrainingError: LocalizedError {
        case insufficientViews
        case datasetLoadFailed
        case emptyInitialization
        case lowMemory
        case datasetAssetsMissing
        case thermal

        var errorDescription: String? {
            switch self {
            case .insufficientViews:
                return "有效视角少于 6 个，请环绕主体多采集几组画面。"
            case .datasetLoadFailed:
                return "训练器无法读取 transforms.json 或图像目录。"
            case .emptyInitialization:
                return "训练器没有得到有效的 Gaussian 初始化。"
            case .lowMemory:
                return "当前可用内存低于 1.2 GB。请关闭其他应用或减少后台任务后再训练。"
            case .datasetAssetsMissing:
                return "训练数据缺少有效的 LiDAR 点云或相机图像，请重新采集。"
            case .thermal:
                return "设备当前温度较高，已暂停 3DGS 训练。请等待 iPhone 冷却后再试。"
            }
        }
    }
}
