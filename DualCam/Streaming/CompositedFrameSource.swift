import AVFoundation
import CoreVideo
import Foundation

/// Fan-out point for the already-composited preview frame.
/// Callers must keep work bounded and must not block the camera's video queue.
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

        let frame = Frame(
            pixelBuffer: pixelBuffer,
            presentationTime: presentationTime,
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        currentSink(frame)
    }
}
