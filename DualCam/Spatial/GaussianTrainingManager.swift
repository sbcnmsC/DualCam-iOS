import CoreGraphics
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
        exportedSPZ = nil
        totalIterations = max(500, min(iterationTarget, 4_000))
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
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.phase = .failed(error.localizedDescription)
                    self.status = error.localizedDescription
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
        config.shDegree = 2
        config.stopDensifyAt = Int32(iterations * 2 / 3)
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
                if ProcessInfo.processInfo.thermalState == .critical {
                    stopReason = "设备温度过高，已停止训练并导出当前结果"
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

        let plyURL = outputDirectory.appendingPathComponent("trained_gaussian_splats.ply")
        let spzURL = outputDirectory.appendingPathComponent("trained_gaussian_splats.spz")
        try? FileManager.default.removeItem(at: plyURL)
        try? FileManager.default.removeItem(at: spzURL)
        trainer.exportPly(to: plyURL.path)
        trainer.exportSpz(to: spzURL.path)

        let hasPLY = FileManager.default.fileExists(atPath: plyURL.path)
        let hasSPZ = FileManager.default.fileExists(atPath: spzURL.path)
        let wasCancelled = cancelFlag.isCancelled
        let finalIteration = trainer.iteration
        let finalSplatCount = trainer.splatCount

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.iteration = finalIteration
            self.splatCount = finalSplatCount
            self.exportedPLY = hasPLY ? plyURL : nil
            self.exportedSPZ = hasSPZ ? spzURL : nil
            if hasPLY {
                self.phase = wasCancelled ? .cancelled : .finished
                self.status = stopReason ?? "训练完成 · 已导出优化后的 Gaussian 场景"
            } else {
                self.phase = .failed("训练完成但没有生成 PLY 文件")
                self.status = "训练结果导出失败"
            }
            self.worker = nil
            let completion = self.onTrainingFinished
            self.onTrainingFinished = nil
            completion?()
        }
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

        var errorDescription: String? {
            switch self {
            case .insufficientViews:
                return "有效视角少于 6 个，请环绕主体多采集几组画面。"
            case .datasetLoadFailed:
                return "训练器无法读取 transforms.json 或图像目录。"
            case .emptyInitialization:
                return "训练器没有得到有效的 Gaussian 初始化。"
            }
        }
    }
}
