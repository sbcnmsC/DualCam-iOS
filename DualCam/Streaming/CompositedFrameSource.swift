import AVFoundation
import CoreVideo
import Foundation

/// Non-blocking fan-out point for DualCam's final rendered preview.
/// This intentionally publishes the same buffer that drives the local preview layer:
/// PiP/split, crop/aspect and filter are already baked in.
final class CompositedFrameSource {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let presentationTime: CMTime
        let width: Int
        let height: Int
    }

    typealias Sink = (Frame) -> Void

    private let lock = NSLock()
    private var sink: Sink?

    func setSink(_ sink: Sink?) {
        lock.lock()
        self.sink = sink
        lock.unlock()
    }

    func publish(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        lock.lock()
        let currentSink = sink
        lock.unlock()
        guard let currentSink else { return }

        currentSink(Frame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        ))
    }
}
