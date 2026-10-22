import AVFoundation
import CoreImage
import Foundation

/// 对 AVAssetWriter 的封装：写入合成画面（或单路原片）和可选的音频。
/// 传入 liveID 时写成「实况照片」配套的短视频（带 content identifier 和 still-image-time 元数据）。
final class VideoRecorder {
    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private let metadataInput: AVAssetWriterInput?
    private let metadataAdaptor: AVAssetWriterInputMetadataAdaptor?
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let queue = DispatchQueue(label: "dualcam.writer")
    private let width: Int
    private let height: Int
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // Bound the number of video buffers in flight. Under encoder pressure, dropping a
    // late frame is preferable to retaining an unbounded queue of large BGRA buffers.
    private let pendingVideoLock = NSLock()
    private var pendingVideoFrames = 0
    private let maxPendingVideoFrames = 3

    // 以下仅在 queue 上访问
    private var sessionStarted = false
    private var finishing = false
    private var lastPTS = CMTime.invalid

    init(width: Int, height: Int, fps: Int, audioSettings: [String: Any]?, liveID: String? = nil) throws {
        self.width = width
        self.height = height
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dualcam-\(UUID().uuidString).mov")
        let w = try AVAssetWriter(outputURL: fileURL, fileType: .mov)
        url = fileURL
        writer = w

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
        if !w.canApply(outputSettings: settings, forMediaType: .video) {
            settings[AVVideoCodecKey] = AVVideoCodecType.h264
        }
        let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        vInput.expectsMediaDataInRealTime = true
        videoInput = vInput
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: vInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ])
        if w.canAdd(vInput) { w.add(vInput) }

        if let audioSettings = audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if w.canAdd(input) {
                w.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        // 实况照片：文件级 content identifier + 一条 still-image-time 元数据轨道
        if let liveID = liveID {
            let idItem = AVMutableMetadataItem()
            idItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            idItem.key = "com.apple.quicktime.content.identifier" as NSString
            idItem.value = liveID as NSString
            idItem.dataType = "com.apple.metadata.datatype.UTF-8"
            w.metadata = [idItem]

            let spec: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
                    "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
                    "com.apple.metadata.datatype.int8"
            ]
            var desc: CMFormatDescription?
            CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [spec] as CFArray,
                formatDescriptionOut: &desc)
            if let desc = desc {
                let mInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: desc)
                if w.canAdd(mInput) {
                    w.add(mInput)
                    metadataInput = mInput
                    metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: mInput)
                } else {
                    metadataInput = nil
                    metadataAdaptor = nil
                }
            } else {
                metadataInput = nil
                metadataAdaptor = nil
            }
        } else {
            metadataInput = nil
            metadataAdaptor = nil
        }
    }

    func start() -> Bool {
        return writer.startWriting()
    }

    /// Reserve queue capacity before doing full-resolution pixel work.
    /// Once the small real-time queue is full, the incoming frame is dropped immediately.
    private func reserveVideoFrame() -> Bool {
        pendingVideoLock.lock()
        defer { pendingVideoLock.unlock() }
        guard pendingVideoFrames < maxPendingVideoFrames else { return false }
        pendingVideoFrames += 1
        return true
    }

    private func releaseVideoFrame() {
        pendingVideoLock.lock()
        pendingVideoFrames = max(0, pendingVideoFrames - 1)
        pendingVideoLock.unlock()
    }

    /// Composite frames can be expensive at 4K. Apply back-pressure before allocating or
    /// rendering, then cap the pixel-buffer pool as a second guard against memory spikes.
    func appendComposite(_ image: CIImage, context: CIContext, time: CMTime) {
        guard reserveVideoFrame() else { return }
        guard let pool = adaptor.pixelBufferPool else {
            releaseVideoFrame()
            return
        }
        var created: CVPixelBuffer?
        let poolLimits: [String: Any] = [
            kCVPixelBufferPoolAllocationThresholdKey as String: 5
        ]
        let result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, poolLimits as CFDictionary, &created
        )
        guard result == kCVReturnSuccess, let buffer = created else {
            releaseVideoFrame()
            return
        }
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                       colorSpace: outputColorSpace)
        enqueueReservedBuffer(buffer, time: time)
    }

    /// Raw camera frames use the same bounded admission policy, avoiding a growing queue
    /// of retained capture buffers when the encoder cannot keep up.
    func appendRaw(_ buffer: CVPixelBuffer, time: CMTime) {
        guard reserveVideoFrame() else { return }
        enqueueReservedBuffer(buffer, time: time)
    }

    /// Caller must hold one reservation; it is released on every exit path.
    private func enqueueReservedBuffer(_ buffer: CVPixelBuffer, time: CMTime) {
        queue.async {
            defer { self.releaseVideoFrame() }
            guard !self.finishing, self.writer.status == .writing else { return }
            if !self.sessionStarted {
                self.writer.startSession(atSourceTime: time)
                self.sessionStarted = true
                if let ma = self.metadataAdaptor {
                    let item = AVMutableMetadataItem()
                    item.keySpace = AVMetadataKeySpace(rawValue: "mdta")
                    item.key = "com.apple.quicktime.still-image-time" as NSString
                    item.value = 0 as NSNumber
                    item.dataType = "com.apple.metadata.datatype.int8"
                    ma.append(AVTimedMetadataGroup(
                        items: [item],
                        timeRange: CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 100))))
                }
            }
            // 时间戳必须严格递增
            if self.lastPTS.isValid && time <= self.lastPTS { return }
            if self.videoInput.isReadyForMoreMediaData {
                if self.adaptor.append(buffer, withPresentationTime: time) {
                    self.lastPTS = time
                }
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
            self.metadataInput?.markAsFinished()
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
