import AVFoundation
import CoreImage
import ImageIO
import Photos
import UniformTypeIdentifiers

enum LivePhotoWriterError: LocalizedError {
    case noFrames
    case invalidStillFrameIndex
    case inconsistentFrameDimensions
    case cannotCreateMetadata
    case cannotStartWriter
    case cannotCreatePixelBuffer
    case cannotAppendVideo
    case cannotAppendStillTime

    var errorDescription: String? {
        switch self {
        case .noFrames: return "实况视频没有有效帧"
        case .invalidStillFrameIndex: return "实况关键帧索引无效"
        case .inconsistentFrameDimensions: return "实况视频帧尺寸不一致"
        case .cannotCreateMetadata: return "无法创建实况照片元数据"
        case .cannotStartWriter: return "无法启动实况视频编码"
        case .cannotCreatePixelBuffer: return "无法创建实况视频帧"
        case .cannotAppendVideo: return "写入实况视频帧失败"
        case .cannotAppendStillTime: return "写入实况照片关键帧时间失败"
        }
    }
}

/// Live Photo resource helper:
/// - JPEG MakerApple["17"] and MOV content.identifier share the same UUID.
/// - MOV includes a QuickTime still-image-time metadata track.
enum LivePhotoMovieWriter {
    static func photoJPEG(from image: CIImage,
                          context: CIContext,
                          colorSpace: CGColorSpace,
                          identifier: String) -> Data? {
        let bounds = image.extent.integral
        guard let cgImage = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: colorSpace) else {
            return nil
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyMakerAppleDictionary: ["17": identifier],
            kCGImageDestinationLossyCompressionQuality: 1.0
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    /// Store preview-sized JPEGs in a rolling buffer so Live Photo capture doesn't retain full-resolution
    /// CVPixelBuffers for several seconds. The longest edge is 720 px and dimensions are forced even.
    static func videoFrameJPEG(from image: CIImage,
                               context: CIContext,
                               colorSpace: CGColorSpace) -> Data? {
        let bounds = image.extent.integral
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let scale = min(1.0, 720.0 / max(bounds.width, bounds.height))
        let width = max(2, Int((bounds.width * scale).rounded(.down)) / 2 * 2)
        let height = max(2, Int((bounds.height * scale).rounded(.down)) / 2 * 2)
        let size = CGSize(width: width, height: height)
        let rect = CGRect(origin: .zero, size: size)
        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / bounds.width,
            y: CGFloat(height) / bounds.height
        )).cropped(to: rect)

        let qualityKey = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return context.jpegRepresentation(of: scaled, colorSpace: colorSpace, options: [qualityKey: 0.82])
    }

    static func writePairedMovie(identifier: String,
                                 jpegFrames: [Data],
                                 stillFrameIndex: Int,
                                 completion: @escaping (Result<URL, Error>) -> Void) {
        guard let firstData = jpegFrames.first,
              let source = CGImageSourceCreateWithData(firstData as CFData, nil),
              let firstImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              jpegFrames.count >= 3 else {
            completion(.failure(LivePhotoWriterError.noFrames))
            return
        }

        // A Live Photo's still-image-time marker must refer to the exact frame
        // represented by the paired still image. Reject invalid indices instead
        // of silently clamping them to a different frame.
        guard jpegFrames.indices.contains(stillFrameIndex) else {
            completion(.failure(LivePhotoWriterError.invalidStillFrameIndex))
            return
        }

        // Every buffered frame should come from the same composed canvas. Reject
        // malformed or mixed-size JPEGs instead of stretching a bad frame into
        // the output dimensions and producing a visually inconsistent Live Photo.
        for data in jpegFrames {
            guard let frameSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let frame = CGImageSourceCreateImageAtIndex(frameSource, 0, nil) else {
                completion(.failure(LivePhotoWriterError.noFrames))
                return
            }
            guard frame.width == firstImage.width, frame.height == firstImage.height else {
                completion(.failure(LivePhotoWriterError.inconsistentFrameDimensions))
                return
            }
        }

        let width = max(2, firstImage.width / 2 * 2)
        let height = max(2, firstImage.height / 2 * 2)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-photo-\(UUID().uuidString).mov")
        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: max(1_500_000, width * height * 4),
                    AVVideoExpectedSourceFrameRateKey: 10,
                    AVVideoMaxKeyFrameIntervalKey: 10
                ] as [String: Any]
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            videoInput.expectsMediaDataInRealTime = false
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: width,
                    kCVPixelBufferHeightKey as String: height,
                    kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
                ]
            )
            guard writer.canAdd(videoInput) else {
                throw LivePhotoWriterError.cannotStartWriter
            }
            writer.add(videoInput)

            let contentIdentifier = AVMutableMetadataItem()
            contentIdentifier.keySpace = .quickTimeMetadata
            contentIdentifier.key = "com.apple.quicktime.content.identifier" as NSString
            contentIdentifier.value = identifier as NSString
            contentIdentifier.dataType = "com.apple.metadata.datatype.UTF-8"
            writer.metadata = [contentIdentifier]

            let specification: NSDictionary = [
                kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as NSString:
                    "mdta/com.apple.quicktime.still-image-time",
                kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as NSString:
                    "com.apple.metadata.datatype.int8"
            ]
            var metadataDescription: CMMetadataFormatDescription?
            let metadataStatus = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(
                allocator: kCFAllocatorDefault,
                metadataType: kCMMetadataFormatType_Boxed,
                metadataSpecifications: [specification] as CFArray,
                formatDescriptionOut: &metadataDescription
            )
            guard metadataStatus == noErr, let metadataDescription else {
                throw LivePhotoWriterError.cannotCreateMetadata
            }

            let metadataInput = AVAssetWriterInput(
                mediaType: .metadata,
                outputSettings: nil,
                sourceFormatHint: metadataDescription
            )
            metadataInput.expectsMediaDataInRealTime = false
            guard writer.canAdd(metadataInput) else {
                throw LivePhotoWriterError.cannotCreateMetadata
            }
            writer.add(metadataInput)
            let metadataAdaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)

            guard writer.startWriting() else {
                throw writer.error ?? LivePhotoWriterError.cannotStartWriter
            }
            writer.startSession(atSourceTime: .zero)

            guard let pixelBufferPool = adaptor.pixelBufferPool else {
                throw LivePhotoWriterError.cannotCreatePixelBuffer
            }

            for (index, jpeg) in jpegFrames.enumerated() {
                guard let imageSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    throw LivePhotoWriterError.noFrames
                }
                let image = CIImage(cgImage: cgImage)
                let frameRect = CGRect(x: 0, y: 0, width: width, height: height)
                let fitted = image.transformed(by: CGAffineTransform(
                    scaleX: CGFloat(width) / image.extent.width,
                    y: CGFloat(height) / image.extent.height
                )).cropped(to: frameRect)

                var optionalBuffer: CVPixelBuffer?
                let allocationStatus = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &optionalBuffer)
                guard allocationStatus == kCVReturnSuccess, let pixelBuffer = optionalBuffer else {
                    throw LivePhotoWriterError.cannotCreatePixelBuffer
                }
                context.render(fitted, to: pixelBuffer, bounds: frameRect, colorSpace: colorSpace)

                while !videoInput.isReadyForMoreMediaData {
                    if writer.status == .failed {
                        throw writer.error ?? LivePhotoWriterError.cannotAppendVideo
                    }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                let pts = CMTime(value: Int64(index), timescale: 10)
                guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                    throw writer.error ?? LivePhotoWriterError.cannotAppendVideo
                }
            }

            let stillTime = CMTime(value: Int64(stillFrameIndex), timescale: 10)
            let stillItem = AVMutableMetadataItem()
            stillItem.keySpace = AVMetadataKeySpace(rawValue: "mdta")
            stillItem.key = "com.apple.quicktime.still-image-time" as NSString
            stillItem.value = NSNumber(value: 0)
            stillItem.dataType = "com.apple.metadata.datatype.int8"
            let duration = CMTime(value: 1, timescale: 10)
            let group = AVTimedMetadataGroup(
                items: [stillItem],
                timeRange: CMTimeRange(start: stillTime, duration: duration)
            )
            while !metadataInput.isReadyForMoreMediaData {
                if writer.status == .failed {
                    throw writer.error ?? LivePhotoWriterError.cannotAppendStillTime
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
            guard metadataAdaptor.append(group) else {
                throw writer.error ?? LivePhotoWriterError.cannotAppendStillTime
            }

            videoInput.markAsFinished()
            metadataInput.markAsFinished()
            writer.finishWriting {
                if writer.status == .completed {
                    completion(.success(outputURL))
                } else {
                    try? FileManager.default.removeItem(at: outputURL)
                    completion(.failure(writer.error ?? LivePhotoWriterError.cannotStartWriter))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            completion(.failure(error))
        }
    }
}
