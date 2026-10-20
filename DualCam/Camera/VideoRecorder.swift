import AVFoundation
import CoreImage
import Foundation

/// 对 AVAssetWriter 的封装：写入合成画面（或单路原片）和可选的音频。
final class VideoRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "dualcam.writer")
    private let width: Int
    private let height: Int
    // 以下仅在 queue 上访问
    private var sessionStarted = false
    private var finishing = false

    init(width: Int, height: Int, fps: Int, audioSettings: [String: Any]?) throws {
        self.width = width
        self.height = height
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dualcam-\(UUID().uuidString).mov")
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let bitrate = max(4_000_000, width * height * 5)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: fps
            ] as [String: Any]
        ]
        if !writer.canApply(outputSettings: settings, forMediaType: .video) {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ])
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        if let audioSettings = audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }
    }

    func start() -> Bool {
        return writer.startWriting()
    }

    /// 把合成后的图像渲染进像素缓冲并写入。在调用线程渲染，在写入队列提交。
    func appendComposite(_ image: CIImage, context: CIContext, time: CMTime) {
        guard let pool = adaptor.pixelBufferPool else { return }
        var created: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
        guard let buffer = created else { return }
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        appendBuffer(buffer, time: time)
    }

    /// 直接写入一路原始画面。
    func appendRaw(_ buffer: CVPixelBuffer, time: CMTime) {
        appendBuffer(buffer, time: time)
    }

    private func appendBuffer(_ buffer: CVPixelBuffer, time: CMTime) {
        queue.async {
            guard !self.finishing, self.writer.status == .writing else { return }
            if !self.sessionStarted {
                self.writer.startSession(atSourceTime: time)
                self.sessionStarted = true
            }
            if self.videoInput.isReadyForMoreMediaData {
                self.adaptor.append(buffer, withPresentationTime: time)
            }
        }
    }

    func appendAudio(_ sample: CMSampleBuffer) {
        guard let input = audioInput else { return }
        queue.async {
            guard !self.finishing, self.sessionStarted, self.writer.status == .writing else { return }
            if input.isReadyForMoreMediaData {
                input.append(sample)
            }
        }
    }

    func finish(_ completion: @escaping (URL?) -> Void) {
        queue.async {
            self.finishing = true
            guard self.sessionStarted, self.writer.status == .writing else {
                self.writer.cancelWriting()
                try? FileManager.default.removeItem(at: self.url)
                completion(nil)
                return
            }
            self.videoInput.markAsFinished()
            self.audioInput?.markAsFinished()
            self.writer.finishWriting {
                if self.writer.status == .completed {
                    completion(self.url)
                } else {
                    try? FileManager.default.removeItem(at: self.url)
                    completion(nil)
                }
            }
        }
    }
}
