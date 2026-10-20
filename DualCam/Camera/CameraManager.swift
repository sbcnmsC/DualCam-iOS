import AVFoundation
import AudioToolbox
import CoreImage
import ImageIO
import Photos
import SwiftUI
import UIKit

private struct LivePhotoFrame {
    let seconds: Double
    let data: Data
}

private struct PendingLivePhotoCapture {
    let identifier: String
    let requestedAt: Double
    let stillPhotoData: Data
    let keyVideoFrame: Data
    let preFrames: [LivePhotoFrame]
    var postFrames: [LivePhotoFrame]
}

final class CameraManager: NSObject, ObservableObject {

    // MARK: - 界面状态（只在主线程修改）

    @Published var cfg = Config() { didSet { cfgDidChange(oldValue) } }
    @Published var slotStates: [SlotState] = [SlotState(), SlotState()]
    @Published var slotInfos: [SlotInfo] = [SlotInfo(), SlotInfo()]
    @Published var combos: [LensCombo] = []
    @Published var comboIndex = 0
    @Published var statusText = "正在准备相机…"
    @Published var ready = false
    @Published var permissionDenied = false
    @Published var captureMode: CaptureMode = .photo
    @Published var isRecording = false
    @Published var recordSeconds = 0
    @Published var countdown: Int? = nil
    @Published var screenFlash = false
    @Published var flashEnabled = false
    @Published var timerSeconds = 0
    @Published var livePhotoEnabled = false {
        didSet {
            lock.lock()
            sharedLivePhotoEnabled = livePhotoEnabled
            lock.unlock()
        }
    }
    @Published var toast: String? = nil
    @Published var outputLabel = ""
    @Published var effectiveFPS = 30
    @Published var filterThumbs: [String: UIImage] = [:]
    @Published var thumbsActive = false { didSet { setSharedThumbs(thumbsActive) } }
    @Published var paramTarget = 0
    @Published var focusMarker: FocusMarker? = nil

    /// 预览显示层：和系统相机同一条硬件通路，IOSurface 零拷贝。
    /// 在 UI 里通过 PreviewRepresentable 挂载到 DisplayLayerHostView。
    let displayLayer = AVSampleBufferDisplayLayer()

    var mainSlot: Int { cfg.swapped ? 1 : 0 }

    // MARK: - 采集对象

    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "dualcam.session")
    // 主渲染/显示队列：userInteractive 保证帧回调不被其它任务挤占，预览才跟手。
    private let videoQueue = DispatchQueue(label: "dualcam.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "dualcam.audio")
    private let livePhotoQueue = DispatchQueue(label: "dualcam.live-photo", qos: .userInitiated)
    private let thumbnailQueue = DispatchQueue(label: "dualcam.thumbnails", qos: .utility)
    private let outputA = AVCaptureVideoDataOutput()
    private let outputB = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    // 关闭颜色管理 + 不缓存中间结果：8-bit 实时管线里明显省 GPU。
    private let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .cacheIntermediates: false
    ])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // sessionQueue 独占
    private var devices: [AVCaptureDevice?] = [nil, nil]
    private var currentCombo: LensCombo?
    private var audioGranted = false
    private var audioActive = false
    private var restartCount = 0

    // 渲染线程与主线程共享（用 lock 保护）
    private let lock = NSLock()
    private var sharedCfg = Config()
    private var sharedThumbs = false
    private var sharedLivePhotoEnabled = false
    private var latest: [CVPixelBuffer?] = [nil, nil]
    private var bufferSizes: [CGSize] = [.zero, .zero]
    private var slotFront: [Bool] = [false, false]
    private var lastCanvas = CGSize(width: 1080, height: 1920)
    private var lastThumbTime: Double = 0
    private var sharedFPS = 30

    // 录像状态（用 recLock 保护）
    private let recLock = NSLock()
    private var recorder: VideoRecorder?
    private var rawRecorders: [VideoRecorder?] = [nil, nil]

    private var recTimer: Timer?
    private var countdownTimer: Timer?
    private var dragSlot = 0
    private var dragStartBias: Float = 0
    private var pendingZoomAfterRebuild: (slot: Int, display: CGFloat)?

    // 这些只在 videoQueue 上访问。
    private var liveFrames: [LivePhotoFrame] = []
    private var lastLivePhotoFrameSeconds = -Double.infinity
    private var pendingLivePhotoCapture: PendingLivePhotoCapture?
    private var lastCompositePTS = CMTime.zero

    // 预览像素缓冲池：IOSurface + Metal，直接喂给 displayLayer，零拷贝。
    private var canvasPool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    // display() 缓存格式描述，尺寸不变就不重复创建。
    private var displayFormatDescription: CMVideoFormatDescription?
    private var displayFormatSize: CGSize?

    // MARK: - 启动

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        observeNotifications()
        requestPermissionsAndStart()
    }

    private func requestPermissionsAndStart() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                DispatchQueue.main.async {
                    self.permissionDenied = true
                    self.statusText = "请在「设置」中允许 DualCam 使用相机"
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                self.sessionQueue.async {
                    self.audioGranted = audioOK
                    self.discoverAndStart()
                }
            }
        }
    }

    private func discoverAndStart() {
        guard AVCaptureMultiCamSession.isMultiCamSupported else {
            postStatus("此设备不支持前后双摄同步采集")
            return
        }
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified)
        let sets = discovery.supportedMultiCamDeviceSets

        func device(_ spec: LensSpec) -> AVCaptureDevice? {
            return AVCaptureDevice.default(spec.deviceType, for: .video, position: spec.position)
        }
        let pairs: [(LensSpec, LensSpec)] = [
            (.backWide, .front), (.backUltra, .front), (.backTele, .front),
            (.backWide, .backUltra), (.backWide, .backTele)
        ]
        var found: [LensCombo] = []
        for (a, b) in pairs {
            if let da = device(a), let db = device(b),
               sets.contains(where: { $0.contains(da) && $0.contains(db) }) {
                found.append(LensCombo(a: a, b: b))
            }
        }
        guard let first = found.first else {
            postStatus("没有可同时使用的摄像头组合")
            return
        }
        currentCombo = first
        DispatchQueue.main.async {
            self.combos = found
            self.comboIndex = 0
        }
        rebuild(resetStates: true)
    }

    // MARK: - 会话构建

    private func targetHeights() -> [Int] {
        switch snapshot().resolution {
        case .p720: return [720]
        case .p1080: return [1080, 720]
        case .maximum: return [2160, 1440, 1080, 720]
        }
    }

    private func rebuild(attempt: Int = 0, resetStates: Bool = false) {
        guard let combo = currentCombo else { return }
        if session.isRunning { session.stopRunning() }

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        devices = [nil, nil]
        audioActive = false

        let specs = [combo.a, combo.b]
        let outputs = [outputA, outputB]
        let heights = targetHeights()
        let height = heights[min(attempt, heights.count - 1)]
        let wantFPS = snapshot().fps
        var usedFPS = wantFPS
        var failure: String? = nil
        var infos: [SlotInfo] = [SlotInfo(), SlotInfo()]

        for i in 0..<2 {
            let spec = specs[i]
            guard let dev = AVCaptureDevice.default(spec.deviceType, for: .video, position: spec.position),
                  let input = try? AVCaptureDeviceInput(device: dev),
                  session.canAddInput(input) else {
                failure = "无法使用「\(spec.title)」摄像头"
                break
            }
            session.addInputWithNoConnections(input)
            usedFPS = min(usedFPS, configureFormat(dev, targetHeight: height, fps: wantFPS))

            let out = outputs[i]
            out.alwaysDiscardsLateVideoFrames = true
            out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            out.setSampleBufferDelegate(self, queue: videoQueue)
            guard session.canAddOutput(out) else {
                failure = "无法创建视频输出"
                break
            }
            session.addOutputWithNoConnections(out)
            guard let port = input.ports(for: .video, sourceDeviceType: dev.deviceType, sourceDevicePosition: dev.position).first else {
                failure = "无法获取摄像头端口"
                break
            }
            let conn = AVCaptureConnection(inputPorts: [port], output: out)
            guard session.canAddConnection(conn) else {
                failure = "当前设备不支持该摄像头组合"
                break
            }
            session.addConnection(conn)
            if conn.isVideoRotationAngleSupported(90) { conn.videoRotationAngle = 90 }
            if conn.isVideoMirroringSupported {
                conn.automaticallyAdjustsVideoMirroring = false
                conn.isVideoMirrored = false
            }
            if conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = snapshot().stabilization ? .auto : .off
            }
            devices[i] = dev
            infos[i] = makeInfo(device: dev, spec: spec)
        }

        if failure == nil, audioGranted {
            addAudio()
        }
        session.commitConfiguration()

        if let failure = failure {
            postStatus(failure)
            return
        }

        let exceedsMultiCamBudget = session.hardwareCost > 1.0 || session.systemPressureCost > 1.0
        if exceedsMultiCamBudget {
            if attempt + 1 < heights.count {
                rebuild(attempt: attempt + 1, resetStates: resetStates)
                return
            }

            // Do not report a ready session when the lowest supported format still
            // exceeds the MultiCam resource budget. This is especially important on
            // devices where a front/rear lens pair is supported but the requested
            // quality cannot be sustained concurrently.
            session.stopRunning()
            postStatus("当前摄像头组合超出多摄资源预算，请降低帧率或更换镜头组合")
            DispatchQueue.main.async {
                self.ready = false
                self.statusText = "双摄资源不足"
            }
            return
        }

        lock.lock()
        slotFront = [specs[0] == .front, specs[1] == .front]
        latest = [nil, nil]
        bufferSizes = [.zero, .zero]
        sharedFPS = usedFPS
        lock.unlock()

        // 新会话开始：丢弃旧缓冲，避免首帧黑屏 / 残影。
        videoQueue.async {
            self.displayLayer.flush()
            self.canvasPool = nil
            self.poolSize = .zero
            self.displayFormatDescription = nil
            self.displayFormatSize = nil
        }

        session.startRunning()
        restartCount = 0
        let running = session.isRunning
        DispatchQueue.main.async {
            self.slotInfos = infos
            self.effectiveFPS = usedFPS
            self.ready = running
            self.statusText = running ? "双摄已启动" : "相机未能启动"
            if resetStates { self.slotStates = [SlotState(), SlotState()] }
            if let pending = self.pendingZoomAfterRebuild {
                self.pendingZoomAfterRebuild = nil
                let info = infos[pending.slot]
                let factor = pending.display / max(info.baseMultiplier, 0.01)
                self.slotStates[pending.slot].zoom = min(max(factor, 1), max(info.maxZoom, 1))
            }
            for i in 0..<2 {
                self.applyZoom(i)
                self.applyFocus(i)
                self.applyExposure(i)
                self.applyWhiteBalance(i)
            }
        }
    }

    private func addAudio() {
        guard let mic = AVCaptureDevice.default(for: .audio),
              let micInput = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(micInput) else { return }
        session.addInputWithNoConnections(micInput)
        guard session.canAddOutput(audioOutput) else { return }
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        session.addOutputWithNoConnections(audioOutput)
        let ports = micInput.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: mic.position)
        guard !ports.isEmpty else { return }
        let conn = AVCaptureConnection(inputPorts: ports, output: audioOutput)
        if session.canAddConnection(conn) {
            session.addConnection(conn)
            audioActive = true
        }
    }

    /// 选择多摄支持的格式和帧率，返回实际生效的帧率。
    private func configureFormat(_ dev: AVCaptureDevice, targetHeight: Int, fps: Int) -> Int {
        var chosenFPS = fps

        func supports(_ f: AVCaptureDevice.Format, _ rate: Int) -> Bool {
            return f.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(rate) && Double(rate) <= $0.maxFrameRate
            }
        }
        func score(_ f: AVCaptureDevice.Format) -> Int {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let h = Int(min(d.width, d.height))
            let is169 = abs(Double(d.width) / Double(max(d.height, 1)) - 16.0 / 9.0) < 0.02
            return abs(h - targetHeight) * 10 + (is169 ? 0 : 5)
        }

        let multi = dev.formats.filter { $0.isMultiCamSupported }
        var pool = multi.filter { supports($0, chosenFPS) }
        if pool.isEmpty {
            chosenFPS = 30
            pool = multi.filter { supports($0, 30) }
        }
        if pool.isEmpty { pool = multi }

        do {
            try dev.lockForConfiguration()
            if let best = pool.min(by: { score($0) < score($1) }) {
                dev.activeFormat = best
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(chosenFPS))
            dev.activeVideoMinFrameDuration = duration
            dev.activeVideoMaxFrameDuration = duration
            if dev.isLowLightBoostSupported {
                dev.automaticallyEnablesLowLightBoostWhenAvailable = snapshot().lowLight
            }
            dev.unlockForConfiguration()
        } catch {
            return chosenFPS
        }
        return chosenFPS
    }

    private func makeInfo(device d: AVCaptureDevice, spec: LensSpec) -> SlotInfo {
        var info = SlotInfo()
        info.name = spec.title
        info.isFront = spec == .front
        let f = d.activeFormat
        info.maxZoom = max(1, min(f.videoMaxZoomFactor, 10))
        info.minISO = f.minISO
        info.maxISO = f.maxISO
        info.minBias = max(d.minExposureTargetBias, -4)
        info.maxBias = min(d.maxExposureTargetBias, 4)
        let minS = max(CMTimeGetSeconds(f.minExposureDuration), 1.0 / 8000.0)
        let frameS = CMTimeGetSeconds(d.activeVideoMaxFrameDuration)
        let maxS = max(min(CMTimeGetSeconds(f.maxExposureDuration), frameS), minS * 2)
        info.minShutter = minS
        info.maxShutter = maxS
        info.hasTorch = d.hasTorch
        info.supportsManualFocus = d.isLockingFocusWithCustomLensPositionSupported
        switch spec {
        case .backUltra:
            info.baseMultiplier = 0.5
        case .backTele:
            var mult: CGFloat = 2
            if let wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
                let wFOV = Double(wide.activeFormat.videoFieldOfView) * Double.pi / 180
                let tFOV = Double(f.videoFieldOfView) * Double.pi / 180
                let denom = tan(tFOV / 2)
                if denom > 0.01 {
                    mult = CGFloat((tan(wFOV / 2) / denom * 2).rounded() / 2)
                }
            }
            info.baseMultiplier = max(mult, 2)
        default:
            info.baseMultiplier = 1
        }
        return info
    }

    private func applyCaptureFlags() {
        let c = snapshot()
        for dev in devices {
            guard let d = dev else { continue }
            if d.isLowLightBoostSupported, (try? d.lockForConfiguration()) != nil {
                d.automaticallyEnablesLowLightBoostWhenAvailable = c.lowLight
                d.unlockForConfiguration()
            }
        }
        for output in [outputA, outputB] {
            for conn in output.connections where conn.isVideoStabilizationSupported {
                conn.preferredVideoStabilizationMode = c.stabilization ? .auto : .off
            }
        }
    }

    // MARK: - 共享快照

    private func snapshot() -> Config {
        lock.lock()
        defer { lock.unlock() }
        return sharedCfg
    }

    private func setSharedThumbs(_ on: Bool) {
        lock.lock()
        sharedThumbs = on
        lock.unlock()
    }

    private func cfgDidChange(_ old: Config) {
        lock.lock()
        sharedCfg = cfg
        lock.unlock()
        let new = cfg
        if old.resolution != new.resolution || old.fps != new.fps {
            sessionQueue.async { self.rebuild() }
        } else if old.lowLight != new.lowLight || old.stabilization != new.stabilization {
            sessionQueue.async { self.applyCaptureFlags() }
        }
    }

    private func postStatus(_ text: String) {
        DispatchQueue.main.async { self.statusText = text }
    }

    func showToast(_ text: String) {
        DispatchQueue.main.async {
            self.toast = text
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                if self.toast == text { self.toast = nil }
            }
        }
    }

    // MARK: - 通知

    private func observeNotifications() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.sessionQueue.async {
                guard self.restartCount < 3 else { return }
                self.restartCount += 1
                self.sessionQueue.asyncAfter(deadline: .now() + 0.5) { self.rebuild() }
            }
        }
        nc.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.statusText = "相机被系统打断"
                if self.isRecording { self.stopRecording() }
            }
        }
        nc.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
            self?.postStatus("双摄已启动")
        }
        nc.addObserver(forName: .AVCaptureDeviceSubjectAreaDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.subjectAreaChanged()
        }
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            if self.isRecording { self.stopRecording() }
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            self.sessionQueue.async {
                if self.currentCombo != nil, !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        }
    }

    // MARK: - 逐帧处理

    private func orient(_ image: CIImage) -> CIImage {
        // 连接已设为竖屏；如果系统没有旋转，兜底转正。
        if image.extent.width > image.extent.height { return image.oriented(.right) }
        return image
    }

    private func processFrame(_ pts: CMTime) {
        lock.lock()
        let c = sharedCfg
        let a = latest[0]
        let b = latest[1]
        let front = slotFront
        let thumbsOn = sharedThumbs
        lock.unlock()
        guard let bufA = a else { return }

        var imgA = orient(CIImage(cvPixelBuffer: bufA))
        if front[0] && c.mirrorFront { imgA = imgA.oriented(.upMirrored) }
        var imgB: CIImage? = nil
        if let bufB = b {
            var tmp = orient(CIImage(cvPixelBuffer: bufB))
            if front[1] && c.mirrorFront { tmp = tmp.oriented(.upMirrored) }
            imgB = tmp
        }

        let mainImage: CIImage
        let subImage: CIImage?
        if c.swapped, let second = imgB {
            mainImage = second
            subImage = imgA
        } else {
            mainImage = imgA
            subImage = imgB
        }

        let canvas = Compositor.canvasSize(aspect: c.aspect, resolution: c.resolution, sourceWidth: mainImage.extent.width)
        let full = CGRect(origin: .zero, size: canvas)
        let composed = Compositor.compose(main: mainImage, sub: subImage, cfg: c, canvas: canvas)
        let finalImage = c.filter.apply(to: composed, intensity: c.filterIntensity).cropped(to: full)
        lastCompositePTS = pts
        collectLivePhotoFrame(finalImage, pts: pts)

        lock.lock()
        let canvasChanged = canvas != lastCanvas
        if canvasChanged { lastCanvas = canvas }
        lock.unlock()
        if canvasChanged {
            let label = "\(Int(canvas.width))×\(Int(canvas.height))"
            DispatchQueue.main.async { self.outputLabel = label }
            // 画布尺寸变了，重建像素缓冲池。
            canvasPool = nil
            poolSize = .zero
            displayFormatDescription = nil
            displayFormatSize = nil
        }

        // Render the final composite once into an IOSurface pixel buffer and reuse it for both preview and recording.
        // This avoids a second full CIContext.render pass on every camera frame.
        if let canvasBuf = renderToPool(finalImage, size: canvas) {
            recLock.lock()
            let rec = recorder
            recLock.unlock()
            rec?.appendPixelBuffer(canvasBuf, time: pts)
            display(canvasBuf, pts: pts)
        }

        // 缩略图计算会生成多张 CGImage；放到独立低优先级队列，避免阻塞相机帧处理。
        let now = CMTimeGetSeconds(pts)
        if thumbsOn && now - lastThumbTime > 0.7 {
            lastThumbTime = now
            thumbnailQueue.async { [weak self] in
                self?.makeThumbnails(from: composed, canvas: canvas)
            }
        }
    }

    /// 从池里拿一块 IOSurface 像素缓冲，把合成图渲染进去。池满 6 块就丢这一帧，
    /// 防止显示/编码短暂积压时无限增长。
    private func renderToPool(_ image: CIImage, size: CGSize) -> CVPixelBuffer? {
        if canvasPool == nil || poolSize != size {
            var pool: CVPixelBufferPool?
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
            CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
            canvasPool = pool
            poolSize = size
        }
        guard let pool = canvasPool else { return nil }
        var pb: CVPixelBuffer?
        let limits: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: 6]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, limits as CFDictionary, &pb
        ) == kCVReturnSuccess, let out = pb else { return nil }
        ciContext.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
        return out
    }

    /// 把像素缓冲包成 CMSampleBuffer 立即送显，不排队。
    private func display(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        if displayLayer.status == .failed { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return }

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        if displayFormatDescription == nil || displayFormatSize != size {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &format)
            displayFormatDescription = format
            displayFormatSize = size
        }
        guard let format = displayFormatDescription else { return }

        // 用相机帧的 PTS 做时间戳，AVSampleBufferDisplayLayer 按这个节奏展示；
        // 同时打 DisplayImmediately 标记，绕过层内任何内部缓冲。
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                 imageBuffer: pixelBuffer,
                                                 formatDescription: format,
                                                 sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample = sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        displayLayer.enqueue(sample)
    }

    private func collectLivePhotoFrame(_ image: CIImage, pts: CMTime) {
        lock.lock()
        let enabled = sharedLivePhotoEnabled
        lock.unlock()

        let seconds = CMTimeGetSeconds(pts)
        guard seconds.isFinite else { return }
        guard enabled || pendingLivePhotoCapture != nil else {
            liveFrames.removeAll(keepingCapacity: true)
            lastLivePhotoFrameSeconds = -Double.infinity
            return
        }

        // JPEG encoding is expensive and must not run on the real-time camera callback.
        // Sample at roughly 8 fps and encode on the dedicated Live Photo queue.
        guard seconds - lastLivePhotoFrameSeconds >= 0.12 else { return }
        lastLivePhotoFrameSeconds = seconds
        let sampledImage = image
        livePhotoQueue.async { [weak self] in
            guard let self,
                  let data = LivePhotoMovieWriter.videoFrameJPEG(
                    from: sampledImage, context: self.ciContext, colorSpace: self.srgb
                  ) else { return }
            let frame = LivePhotoFrame(seconds: seconds, data: data)
            self.videoQueue.async {
                self.acceptEncodedLivePhotoFrame(frame)
            }
        }
    }

    /// Must be called on videoQueue. Keeping this state transition here preserves
    /// the pre/post-frame ordering while the expensive JPEG encoding runs elsewhere.
    private func acceptEncodedLivePhotoFrame(_ frame: LivePhotoFrame) {
        lock.lock()
        let enabled = sharedLivePhotoEnabled
        lock.unlock()
        guard enabled || pendingLivePhotoCapture != nil else { return }

        liveFrames.append(frame)
        let cutoff = frame.seconds - 1.7
        liveFrames.removeAll { $0.seconds < cutoff }

        guard var pending = pendingLivePhotoCapture else { return }
        if frame.seconds > pending.requestedAt + 0.02 {
            pending.postFrames.append(frame)
        }

        if frame.seconds >= pending.requestedAt + 1.4 && pending.postFrames.count >= 8 {
            pendingLivePhotoCapture = nil
            let sequence = pending.preFrames.map(\\.data) + [pending.keyVideoFrame] + pending.postFrames.map(\\.data)
            let stillIndex = pending.preFrames.count

            livePhotoQueue.async {
                LivePhotoMovieWriter.writePairedMovie(
                    identifier: pending.identifier,
                    jpegFrames: sequence,
                    stillFrameIndex: stillIndex
                ) { result in
                    switch result {
                    case .success(let movieURL):
                        self.saveLivePhoto(stillData: pending.stillPhotoData, movieURL: movieURL)
                    case .failure(let error):
                        self.showToast("实况生成失败：\\(error.localizedDescription)")
                    }
                }
            }
        } else {
            pendingLivePhotoCapture = pending
        }
    }

    private func makeThumbnails(from image: CIImage, canvas: CGSize) {
        let tw: CGFloat = 120
        let th = max(2, (tw * canvas.height / canvas.width).rounded())
        let small = image.transformed(by: CGAffineTransform(scaleX: tw / canvas.width, y: th / canvas.height))
        let rect = CGRect(x: 0, y: 0, width: tw, height: th)
        var result: [String: UIImage] = [:]
        for kind in FilterKind.allCases {
            let out = kind.apply(to: small, intensity: 1).cropped(to: rect)
            if let cg = ciContext.createCGImage(out, from: rect, format: .RGBA8, colorSpace: srgb) {
                result[kind.rawValue] = UIImage(cgImage: cg)
            }
        }
        DispatchQueue.main.async { self.filterThumbs = result }
    }

    // MARK: - 变焦 / 参数

    func zoomPresets(slot: Int) -> [CGFloat] {
        return [0.5, 1, 2, 5]
    }

    func selectZoomPreset(_ displayZoom: CGFloat, slot: Int) {
        guard (0..<2).contains(slot), !isRecording else { return }
        let desiredSpec: LensSpec
        if displayZoom < 0.75 {
            desiredSpec = .backUltra
        } else if displayZoom >= 4.0 {
            desiredSpec = .backTele
        } else {
            desiredSpec = .backWide
        }

        guard comboIndex < combos.count else {
            let info = slotInfos[slot]
            guard displayZoom >= info.baseMultiplier else {
                showToast("当前摄像头不支持此焦段")
                return
            }
            setZoom(slot: slot, factor: displayZoom / max(info.baseMultiplier, 0.01))
            return
        }

        let currentSpec = slot == 0 ? combos[comboIndex].a : combos[comboIndex].b
        if currentSpec.position == .front {
            if displayZoom < 1 {
                showToast("前置镜头不支持 0.5×")
                return
            }
            setZoom(slot: slot, factor: displayZoom / max(slotInfos[slot].baseMultiplier, 0.01))
            return
        }

        if currentSpec == desiredSpec {
            let base = max(slotInfos[slot].baseMultiplier, 0.01)
            let factor = displayZoom / base
            guard factor <= slotInfos[slot].maxZoom + 0.01 else {
                showToast("当前镜头无法达到 \(displayZoom)×")
                return
            }
            setZoom(slot: slot, factor: factor)
            return
        }

        if let targetIndex = combos.firstIndex(where: { combo in
            (slot == 0 ? combo.a : combo.b) == desiredSpec
        }) {
            if targetIndex != comboIndex {
                let targetCombo = combos[targetIndex]
                comboIndex = targetIndex
                pendingZoomAfterRebuild = (slot: slot, display: displayZoom)
                ready = false
                sessionQueue.async {
                    self.currentCombo = targetCombo
                    self.rebuild(resetStates: true)
                }
                return
            }
            let base = max(slotInfos[slot].baseMultiplier, 0.01)
            setZoom(slot: slot, factor: displayZoom / base)
            return
        }

        let info = slotInfos[slot]
        guard displayZoom >= info.baseMultiplier,
              displayZoom <= info.baseMultiplier * info.maxZoom + 0.01 else {
            showToast("当前设备不支持 \(displayZoom)× 焦段")
            return
        }
        setZoom(slot: slot, factor: displayZoom / max(info.baseMultiplier, 0.01))
    }

    func displayZoom(slot: Int) -> CGFloat {
        return slotStates[slot].zoom * slotInfos[slot].baseMultiplier
    }

    func setZoom(slot: Int, factor: CGFloat) {
        let m = max(slotInfos[slot].maxZoom, 1)
        slotStates[slot].zoom = min(max(factor, 1), m)
        applyZoom(slot)
    }

    private func withDevice(_ slot: Int, _ body: @escaping (AVCaptureDevice) -> Void) {
        sessionQueue.async { [weak self] in
            guard let self = self, slot < self.devices.count, let d = self.devices[slot] else { return }
            do { try d.lockForConfiguration() } catch { return }
            body(d)
            d.unlockForConfiguration()
        }
    }

    func applyZoom(_ slot: Int) {
        let z = slotStates[slot].zoom
        withDevice(slot) { d in
            d.videoZoomFactor = min(max(z, 1), d.activeFormat.videoMaxZoomFactor)
        }
    }

    func applyFocus(_ slot: Int) {
        let s = slotStates[slot]
        withDevice(slot) { d in
            if s.manualFocus, d.isLockingFocusWithCustomLensPositionSupported {
                d.setFocusModeLocked(lensPosition: s.lensPosition, completionHandler: nil)
            } else if s.locked, d.isFocusModeSupported(.locked) {
                d.focusMode = .locked
            } else if d.isFocusModeSupported(.continuousAutoFocus) {
                d.focusMode = .continuousAutoFocus
            }
        }
    }

    func applyExposure(_ slot: Int) {
        let s = slotStates[slot]
        withDevice(slot) { d in
            if s.manualExposure {
                let f = d.activeFormat
                let iso = min(max(s.iso, f.minISO), f.maxISO)
                let minD = max(CMTimeGetSeconds(f.minExposureDuration), 1.0 / 8000.0)
                let maxD = max(min(CMTimeGetSeconds(f.maxExposureDuration), CMTimeGetSeconds(d.activeVideoMaxFrameDuration)), minD * 2)
                let seconds = minD * pow(maxD / minD, s.shutter)
                d.setExposureModeCustom(duration: CMTimeMakeWithSeconds(seconds, preferredTimescale: 1_000_000),
                                        iso: iso, completionHandler: nil)
            } else if s.locked, d.isExposureModeSupported(.locked) {
                d.exposureMode = .locked
            } else {
                if d.isExposureModeSupported(.continuousAutoExposure) {
                    d.exposureMode = .continuousAutoExposure
                }
                let bias = min(max(s.exposureBias, d.minExposureTargetBias), d.maxExposureTargetBias)
                d.setExposureTargetBias(bias, completionHandler: nil)
            }
        }
    }

    func applyWhiteBalance(_ slot: Int) {
        let s = slotStates[slot]
        withDevice(slot) { d in
            if s.manualWB, d.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                let tt = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: s.temperature, tint: s.tint)
                var gains = d.deviceWhiteBalanceGains(for: tt)
                let m = d.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), m)
                gains.greenGain = min(max(gains.greenGain, 1), m)
                gains.blueGain = min(max(gains.blueGain, 1), m)
                d.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            } else if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                d.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    func toggleLock(_ slot: Int) {
        slotStates[slot].locked.toggle()
        applyFocus(slot)
        applyExposure(slot)
    }

    // MARK: - 点按对焦 / 曝光

    func focus(atNormalized p: CGPoint) {
        let c = cfg
        let regions = Compositor.regions(cfg: c)
        let mainSlot = c.swapped ? 1 : 0
        let subSlot = 1 - mainSlot
        let inSub = regions.sub.contains(p)
        let slot = inSub ? subSlot : mainSlot
        let region = inSub ? regions.sub : regions.main

        lock.lock()
        let canvas = lastCanvas
        let size = bufferSizes[slot]
        lock.unlock()

        let mirrored = slotInfos[slot].isFront && c.mirrorFront
        let dp = Compositor.devicePoint(tap: p, region: region, canvas: canvas, bufferSize: size, mirrored: mirrored)
        let s = slotStates[slot]
        if s.locked { slotStates[slot].locked = false }

        withDevice(slot) { d in
            if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.autoFocus), !s.manualFocus {
                d.focusPointOfInterest = dp
                d.focusMode = .autoFocus
            }
            if d.isExposurePointOfInterestSupported, d.isExposureModeSupported(.autoExpose), !s.manualExposure {
                d.exposurePointOfInterest = dp
                d.exposureMode = .autoExpose
            }
            d.isSubjectAreaChangeMonitoringEnabled = true
        }
        showMarker(at: p)
    }

    func showMarker(at p: CGPoint) {
        let marker = FocusMarker(point: p)
        focusMarker = marker
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if self.focusMarker == marker { self.focusMarker = nil }
        }
    }

    func exposureDragBegan(at p: CGPoint) {
        let c = cfg
        let regions = Compositor.regions(cfg: c)
        let mainSlot = c.swapped ? 1 : 0
        dragSlot = regions.sub.contains(p) ? 1 - mainSlot : mainSlot
        dragStartBias = slotStates[dragSlot].exposureBias
    }

    func exposureDragChanged(dy: CGFloat) {
        let slot = dragSlot
        let s = slotStates[slot]
        guard !s.manualExposure, !s.locked else { return }
        let info = slotInfos[slot]
        let bias = dragStartBias - Float(dy / 70)
        slotStates[slot].exposureBias = min(max(bias, info.minBias), info.maxBias)
        applyExposure(slot)
    }

    private func subjectAreaChanged() {
        DispatchQueue.main.async {
            for i in 0..<2 {
                let s = self.slotStates[i]
                if s.locked || s.manualFocus { continue }
                self.withDevice(i) { d in
                    if d.isFocusPointOfInterestSupported { d.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                    if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
                    if !s.manualExposure {
                        if d.isExposurePointOfInterestSupported { d.exposurePointOfInterest = CGPoint(x: 0.5, y: 0.5) }
                        if d.isExposureModeSupported(.continuousAutoExposure) { d.exposureMode = .continuousAutoExposure }
                    }
                    d.isSubjectAreaChangeMonitoringEnabled = false
                }
            }
        }
    }

    // MARK: - 布局操作

    func toggleLayout() {
        cfg.layout = cfg.layout == .pip ? .split : .pip
    }

    func swapCameras() {
        cfg.swapped.toggle()
    }

    func resetPiP() {
        cfg.pipCenter = CGPoint(x: 0.76, y: 0.20)
        cfg.pipWidth = 0.32
    }

    func snapPiP() {
        guard cfg.pipSnap else { return }
        let r = Compositor.pipRectNormalized(cfg: cfg)
        let margin: CGFloat = 0.03
        let threshold: CGFloat = 0.07
        var cx = r.midX
        var cy = r.midY
        if r.minX < threshold { cx = margin + r.width / 2 }
        else if 1 - r.maxX < threshold { cx = 1 - margin - r.width / 2 }
        else if abs(r.midX - 0.5) < 0.05 { cx = 0.5 }
        if r.minY < threshold { cy = margin + r.height / 2 }
        else if 1 - r.maxY < threshold { cy = 1 - margin - r.height / 2 }
        else if abs(r.midY - 0.5) < 0.05 { cy = 0.5 }
        cfg.pipCenter = CGPoint(x: cx, y: cy)
    }

    func cycleTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
    }

    func cycleCombo() {
        guard !isRecording, combos.count > 1 else { return }
        comboIndex = (comboIndex + 1) % combos.count
        let combo = combos[comboIndex]
        slotStates = [SlotState(), SlotState()]
        paramTarget = 0
        if cfg.swapped { cfg.swapped = false }
        ready = false
        sessionQueue.async {
            self.currentCombo = combo
            self.rebuild(resetStates: true)
        }
    }

    // MARK: - 拍照 / 录像

    func shutterTapped() {
        if countdown != nil {
            cancelCountdown()
            return
        }
        guard ready else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        switch captureMode {
        case .photo:
            runWithCountdown { self.takePhoto() }
        case .video:
            if isRecording {
                stopRecording()
            } else {
                runWithCountdown { self.startRecording() }
            }
        }
    }

    private func runWithCountdown(_ action: @escaping () -> Void) {
        let seconds = timerSeconds
        guard seconds > 0 else {
            action()
            return
        }
        countdown = seconds
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            guard let left = self.countdown else { t.invalidate(); return }
            if left <= 1 {
                t.invalidate()
                self.countdown = nil
                action()
            } else {
                self.countdown = left - 1
            }
        }
    }

    func toggleLivePhoto() {
        livePhotoEnabled.toggle()
        showToast(livePhotoEnabled ? "实况已开启，请等待约 1.5 秒再拍摄" : "实况已关闭")
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
    }

    private func setTorch(slot: Int, on: Bool) {
        withDevice(slot) { d in
            if d.hasTorch, d.isTorchAvailable {
                d.torchMode = on ? .on : .off
            }
        }
    }

    private func flash(on: Bool) {
        let slot = mainSlot
        if slotInfos[slot].hasTorch {
            setTorch(slot: slot, on: on)
        } else {
            screenFlash = on
        }
    }

    func takePhoto() {
        let useFlash = flashEnabled
        if useFlash { flash(on: true) }
        DispatchQueue.main.asyncAfter(deadline: .now() + (useFlash ? 0.45 : 0)) { [weak self] in
            guard let self = self else { return }
            self.videoQueue.async { self.captureStill() }
            if useFlash {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.flash(on: false) }
            }
        }
    }

    private func captureStill() {
        lock.lock()
        let c = sharedCfg
        let a = latest[0]
        let b = latest[1]
        let front = slotFront
        let isLivePhotoCapture = sharedLivePhotoEnabled
        lock.unlock()
        guard let bufA = a else {
            showToast("还没有画面")
            return
        }

        let rawA = orient(CIImage(cvPixelBuffer: bufA))
        var imgA = rawA
        if front[0] && c.mirrorFront { imgA = imgA.oriented(.upMirrored) }
        var rawB: CIImage? = nil
        var imgB: CIImage? = nil
        if let bufB = b {
            let r = orient(CIImage(cvPixelBuffer: bufB))
            rawB = r
            imgB = (front[1] && c.mirrorFront) ? r.oriented(.upMirrored) : r
        }
        let mainImage: CIImage
        let subImage: CIImage?
        if c.swapped, let second = imgB {
            mainImage = second
            subImage = imgA
        } else {
            mainImage = imgA
            subImage = imgB
        }

        let canvas = Compositor.canvasSize(aspect: c.aspect, resolution: c.resolution, sourceWidth: mainImage.extent.width)
        let full = CGRect(origin: .zero, size: canvas)
        let composed = Compositor.compose(main: mainImage, sub: subImage, cfg: c, canvas: canvas)
        let finalImage = c.filter.apply(to: composed, intensity: c.filterIntensity).cropped(to: full)

        if isLivePhotoCapture {
            guard pendingLivePhotoCapture == nil else {
                showToast("上一张实况照片仍在处理中")
                return
            }
            let requestedAt = liveFrames.last?.seconds ?? CMTimeGetSeconds(lastCompositePTS)
            let preFrames = liveFrames.filter { $0.seconds >= requestedAt - 1.5 && $0.seconds <= requestedAt + 0.001 }
            guard preFrames.count >= 8 else {
                showToast("实况正在缓存，请开启后等待约 1.5 秒")
                return
            }
            let identifier = UUID().uuidString
            guard let stillData = LivePhotoMovieWriter.photoJPEG(
                from: finalImage, context: ciContext, colorSpace: srgb, identifier: identifier
            ), let keyFrame = LivePhotoMovieWriter.videoFrameJPEG(
                from: finalImage, context: ciContext, colorSpace: srgb
            ) else {
                showToast("无法生成实况照片")
                return
            }
            var rawPhotos: [Data] = []
            if c.saveRaw {
                if let data = jpeg(rawA) { rawPhotos.append(data) }
                if let rawB, let data = jpeg(rawB) { rawPhotos.append(data) }
            }
            pendingLivePhotoCapture = PendingLivePhotoCapture(
                identifier: identifier,
                requestedAt: requestedAt,
                stillPhotoData: stillData,
                keyVideoFrame: keyFrame,
                preFrames: preFrames,
                postFrames: []
            )
            if !rawPhotos.isEmpty { saveImages(rawPhotos) }
            showToast("照片已拍摄，正在记录实况动态…")
            return
        }

        var datas: [Data] = []
        if let d = jpeg(finalImage) { datas.append(d) }
        if c.saveRaw {
            if let d = jpeg(rawA) { datas.append(d) }
            if let rb = rawB, let d = jpeg(rb) { datas.append(d) }
        }
        guard !datas.isEmpty else {
            showToast("生成照片失败")
            return
        }
        saveImages(datas)
    }

    private func jpeg(_ image: CIImage) -> Data? {
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: image, colorSpace: srgb, options: [key: 1.0])
    }

    private func saveLivePhoto(stillData: Data, movieURL: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else {
                try? FileManager.default.removeItem(at: movieURL)
                return
            }
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: movieURL)
                self.showToast("请在「设置」中允许保存到照片")
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: stillData, options: nil)
                let options = PHAssetResourceCreationOptions()
                options.shouldMoveFile = true
                request.addResource(with: .pairedVideo, fileURL: movieURL, options: options)
            }, completionHandler: { success, error in
                try? FileManager.default.removeItem(at: movieURL)
                self.showToast(success ? "实况照片已保存" : "实况保存失败：\(error?.localizedDescription ?? "未知错误")")
            })
        }
    }

    private func saveImages(_ datas: [Data]) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized || status == .limited else {
                self.showToast("请在「设置」中允许保存到照片")
                return
            }
            PHPhotoLibrary.shared().performChanges({
                for d in datas {
                    let req = PHAssetCreationRequest.forAsset()
                    req.addResource(with: .photo, data: d, options: nil)
                }
            }, completionHandler: { ok, error in
                self.showToast(ok ? "照片已保存" : "保存失败：\(error?.localizedDescription ?? "未知错误")")
            })
        }
    }

    func startRecording() {
        guard !isRecording else { return }
        let useFlash = flashEnabled
        let slot = mainSlot
        videoQueue.async {
            self.lock.lock()
            let c = self.sharedCfg
            let sizes = self.bufferSizes
            let fps = self.sharedFPS
            self.lock.unlock()

            let mainSize = sizes[c.swapped ? 1 : 0]
            guard mainSize.width > 0 else {
                self.showToast("还没有画面")
                return
            }
            let canvas = Compositor.canvasSize(aspect: c.aspect, resolution: c.resolution, sourceWidth: mainSize.width)

            var audioSettings: [String: Any]? = nil
            if self.audioActive {
                if let rec = self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
                    audioSettings = rec
                } else {
                    audioSettings = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: 44100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 96000
                    ]
                }
            }

            do {
                let rec = try VideoRecorder(width: Int(canvas.width), height: Int(canvas.height), fps: fps, audioSettings: audioSettings)
                guard rec.start() else {
                    self.showToast("无法开始录像")
                    return
                }
                var raws: [VideoRecorder?] = [nil, nil]
                if c.saveRaw {
                    for i in 0..<2 where sizes[i].width > 0 {
                        if let r = try? VideoRecorder(width: Int(sizes[i].width), height: Int(sizes[i].height), fps: fps, audioSettings: nil),
                           r.start() {
                            raws[i] = r
                        }
                    }
                }
                self.recLock.lock()
                self.recorder = rec
                self.rawRecorders = raws
                self.recLock.unlock()
                DispatchQueue.main.async {
                    self.isRecording = true
                    self.recordSeconds = 0
                    self.recTimer?.invalidate()
                    self.recTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        self?.recordSeconds += 1
                    }
                    if useFlash, self.slotInfos[slot].hasTorch { self.setTorch(slot: slot, on: true) }
                }
            } catch {
                self.showToast("无法开始录像：\(error.localizedDescription)")
            }
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recTimer?.invalidate()
        recTimer = nil
        let slot = mainSlot
        if slotInfos[slot].hasTorch { setTorch(slot: slot, on: false) }
        videoQueue.async {
            self.recLock.lock()
            let rec = self.recorder
            let raws = self.rawRecorders
            self.recorder = nil
            self.rawRecorders = [nil, nil]
            self.recLock.unlock()

            var all: [VideoRecorder] = []
            if let r = rec { all.append(r) }
            for r in raws { if let r = r { all.append(r) } }
            for r in all {
                r.finish { url in
                    guard let url = url else {
                        self.showToast("录像保存失败")
                        return
                    }
                    self.saveVideo(url)
                }
            }
        }
    }

    private func saveVideo(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized || status == .limited else {
                self.showToast("请在「设置」中允许保存到照片")
                try? FileManager.default.removeItem(at: url)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { ok, error in
                try? FileManager.default.removeItem(at: url)
                self.showToast(ok ? "视频已保存" : "保存失败：\(error?.localizedDescription ?? "未知错误")")
            })
        }
    }
}

// MARK: - 采集回调

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            recLock.lock()
            let rec = recorder
            recLock.unlock()
            rec?.appendAudio(sampleBuffer)
            return
        }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let slot = (output === outputA) ? 0 : 1
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let size = CGSize(width: CVPixelBufferGetWidth(pixel), height: CVPixelBufferGetHeight(pixel))
        lock.lock()
        latest[slot] = pixel
        bufferSizes[slot] = size.width > size.height ? CGSize(width: size.height, height: size.width) : size
        lock.unlock()

        recLock.lock()
        let raw = rawRecorders[slot]
        recLock.unlock()
        raw?.appendRaw(pixel, time: pts)

        if slot == 0 { processFrame(pts) }
    }
}
