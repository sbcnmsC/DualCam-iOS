import AVFoundation
import CoreImage
import Photos
import SwiftUI

enum DualCamLayout { case pictureInPicture, split }

final class CameraManager: NSObject, ObservableObject {
    @Published var previewImage: UIImage?
    @Published var statusText = "正在准备双摄像头…"
    @Published var layout: DualCamLayout = .pictureInPicture
    @Published var isRecording = false
    @Published var showGrid = true
    @Published var flashEnabled = false
    @Published var timerSeconds = 0
    @Published var outputResolution = "1080p"
    @Published var frameRate = 30
    @Published var filterName = "原片"
    @Published var exposure: Double = 0
    private let session = AVCaptureMultiCamSession()
    private let queue = DispatchQueue(label: "dualcamera.capture")
    private let context = CIContext()
    private let mainOutput = AVCaptureVideoDataOutput()
    private let frontOutput = AVCaptureVideoDataOutput()
    private var mainImage: CIImage?
    private var frontImage: CIImage?
    private let lock = NSLock()

    override init() {
        super.init()
        queue.async { self.configure() }
    }

    private func configure() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            DispatchQueue.main.async { self.statusText = "此设备不支持前后双摄同步采集" }
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        defer { session.commitConfiguration() }
        do {
            guard let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
                DispatchQueue.main.async { self.statusText = "无法找到所需摄像头" }; return
            }
            let backInput = try AVCaptureDeviceInput(device: back)
            let frontInput = try AVCaptureDeviceInput(device: front)
            guard session.canAddInput(backInput), session.canAddInput(frontInput) else {
                DispatchQueue.main.async { self.statusText = "当前设备不支持该摄像头组合" }; return
            }
            session.addInputWithNoConnections(backInput)
            session.addInputWithNoConnections(frontInput)
            mainOutput.alwaysDiscardsLateVideoFrames = true
            frontOutput.alwaysDiscardsLateVideoFrames = true
            mainOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            frontOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            mainOutput.setSampleBufferDelegate(self, queue: queue)
            frontOutput.setSampleBufferDelegate(self, queue: queue)
            guard session.canAddOutput(mainOutput), session.canAddOutput(frontOutput) else {
                DispatchQueue.main.async { self.statusText = "无法创建双路视频输出" }; return
            }
            session.addOutputWithNoConnections(mainOutput)
            session.addOutputWithNoConnections(frontOutput)
            if let p = backInput.ports(for: .video, sourceDeviceType: back.deviceType, sourceDevicePosition: .back).first {
                let c = AVCaptureConnection(inputPorts: [p], output: mainOutput)
                if session.canAddConnection(c) { session.addConnection(c) }
            }
            if let p = frontInput.ports(for: .video, sourceDeviceType: front.deviceType, sourceDevicePosition: .front).first {
                let c = AVCaptureConnection(inputPorts: [p], output: frontOutput)
                if session.canAddConnection(c) { session.addConnection(c) }
            }
            session.startRunning()
            DispatchQueue.main.async { self.statusText = "双摄已启动" }
        } catch {
            DispatchQueue.main.async { self.statusText = "启动失败：\(error.localizedDescription)" }
        }
    }

    func toggleLayout() {
        layout = layout == .pictureInPicture ? .split : .pictureInPicture
        render()
    }
    func setZoom(_ factor: CGFloat) {
        guard let d = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
        try? d.lockForConfiguration()
        d.videoZoomFactor = min(max(factor, 1), d.activeFormat.videoMaxZoomFactor)
        d.unlockForConfiguration()
    }
    func cycleTimer() { timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0) }
    func capturePhoto() {
        guard let image = previewImage, let data = image.jpegData(compressionQuality: 0.95) else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else { return }
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
            } completionHandler: { ok, error in
                DispatchQueue.main.async { self.statusText = ok ? "照片已保存" : "保存失败：\(error?.localizedDescription ?? "未知错误")" }
            }
        }
    }
    func toggleRecording() {
        // Video writer/composite recording is not yet wired in this repository version.
        statusText = "录像合成仍待接入"
    }
    private func render() {
        lock.lock(); let back = mainImage; let front = frontImage; lock.unlock()
        guard let back else { return }
        let canvas = CGRect(x: 0, y: 0, width: 720, height: 1280)
        let base = back.transformedToFill(canvas)
        var result = base
        if let front {
            let small = front.transformedToFill(CGRect(x: 470, y: 780, width: 220, height: 390))
            result = layout == .pictureInPicture ? small.composited(over: base) :
                front.transformedToFill(CGRect(x: 0, y: 640, width: 720, height: 640))
                    .composited(over: base.cropped(to: CGRect(x: 0, y: 0, width: 720, height: 640)))
        }
        guard let cg = context.createCGImage(result.cropped(to: canvas), from: canvas) else { return }
        DispatchQueue.main.async { self.previewImage = UIImage(cgImage: cg) }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var image = CIImage(cvPixelBuffer: pixel)
        if output === frontOutput { image = image.oriented(.upMirrored) }
        lock.lock()
        if output === mainOutput { mainImage = image } else { frontImage = image }
        lock.unlock()
        render()
    }
}

private extension CIImage {
    func transformedToFill(_ rect: CGRect) -> CIImage {
        let sx = rect.width / extent.width, sy = rect.height / extent.height
        let scaled = transformed(by: CGAffineTransform(scaleX: max(sx, sy), y: max(sx, sy)))
        return scaled.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: rect.midX - scaled.extent.midX, ty: rect.midY - scaled.extent.midY))
    }
}