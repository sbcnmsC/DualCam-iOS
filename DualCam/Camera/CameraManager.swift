import AVFoundation
import AudioToolbox
import CoreImage
import ImageIO
import Photos
import SwiftUI
import UIKit

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
    @Published var toast: String? = nil
    @Published var outputLabel = ""
    @Published var effectiveFPS = 30
    @Published var filterThumbs: [String: UIImage] = [:]
    @Published var thumbsActive = false { didSet { setSharedThumbs(thumbsActive) } }
    @Published var paramTarget = 0
    @Published var focusMarker: FocusMarker? = nil
    @Published var zoomStops: [ZoomStop] = []
    @Published var lastThumb: UIImage? = nil

    /// 合成后的预览画面直接送进这个显示层（GPU 渲染 → 像素缓冲 → 显示层，不经过 CPU 回读和主线程）。
    let displayLayer: AVSampleBufferDisplayLayer = {
        let l = AVSampleBufferDisplayLayer()
        l.videoGravity = .resizeAspectFill
        l.backgroundColor = UIColor.black.cgColor
        return l
    }()

    var mainSlot: Int { cfg.swapped ? 1 : 0 }

    // MARK: - 采集对象

    private let session = AVCaptureMultiCamSession()
    private let sessionQueue = DispatchQueue(label: "dualcam.session")
    /// A 路（主渲染）队列：合成、预览、写录都在这里。
    private let videoQueue = DispatchQueue(label: "dualcam.video", qos: .userInteractive)
    /// B 路独立队列：只更新「最新帧」和写原片，不再排在 A 路合成后面。
    private let videoQueueB = DispatchQueue(label: "dualcam.video.b", qos: .userInteractive)
    /// 滤镜缩略图队列：缩略图渲染不再堵住实时预览。
    private let thumbQueue = DispatchQueue(label: "dualcam.thumbs", qos: .utility)
    private let audioQueue = DispatchQueue(label: "dualcam.audio")
    private let outputA = AVCaptureVideoDataOutput()
    private let outputB = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    /// 缩略图专用，和实时渲染互不干扰。
    private let thumbContext = CIContext(options: [.cacheIntermediates: false])
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    // sessionQueue 独占
    private var devices: [AVCaptureDevice?] = [nil, nil]
    // 高频滑块只保留最新参数，约 30 次/秒锁定一次设备配置。
    private var pendingDeviceUpdateTokens: [String: UUID] = [:]
    private var pendingDeviceUpdateBodies: [String: (AVCaptureDevice) -> Void] = [:]
    private var lastDeviceUpdateAt: [String: UInt64] = [:]
    private var deviceConfigGeneration: UInt64 = 0
    private var currentCombo: LensCombo?
    private var audioGranted = false
    private var audioActive = false
    private var restartCount = 0
    private var lensBase: [LensSpec: CGFloat] = [:]

    // 渲染线程与主线程共享（用 lock 保护）
    private let lock = NSLock()
    private var sharedCfg = Config()
    private var sharedThumbs = false
    private var thumbsNeedRefresh = false
    private var latest: [CVPixelBuffer?] = [nil, nil]
    private var bufferSizes: [CGSize] = [.zero, .zero]
    private var slotFront: [Bool] = [false, false]
    private var lastCanvas = CGSize(width: 1080, height: 1920)
    private var thumbsBusy = false
    // 只在 videoQueue 上访问：预览像素缓冲池与显示格式缓存
    private var previewPool: CVPixelBufferPool?
    private var previewPoolSize = CGSize.zero
    private var displayFormat: CMVideoFormatDescription?
    private var displayFormatSize = CGSize.zero
    private var sharedFPS = 30
    private var exposureMarkerID: UUID?

    // 录制状态（用 recLock 保护）
    private let recLock = NSLock()
    private var recorder: VideoRecorder?
    private var rawRecorders: [VideoRecorder?] = [nil, nil]
    // 实况照片的配套短视频（同样用 recLock 保护）
    private var liveComposite: VideoRecorder?
    private var liveRaw: [VideoRecorder?] = [nil, nil]
    private let liveSeconds = 1.6

    private var recTimer: Timer?
    private var countdownTimer: Timer?
    private var dragSlot = 0
    private var dragStartBias: Float = 0

    // MARK: - 启动

    override init() {
        super.init()
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

        // 各镜头相对 1× 广角的倍率，以及多摄格式下最大的数码变焦
        var base: [LensSpec: CGFloat] = [.backWide: 1, .backUltra: 0.5, .front: 1]
        var maxZoom: [LensSpec: CGFloat] = [:]
        for spec in [LensSpec.backWide, .backUltra, .backTele, .front] {
            guard let d = device(spec) else { continue }
            let zooms = d.formats.filter { $0.isMultiCamSupported }.map { $0.videoMaxZoomFactor }
            maxZoom[spec] = max(1, zooms.max() ?? 1)
        }
        if let tele = device(.backTele), let wide = device(.backWide) {
            let wFOV = Double(wide.activeFormat.videoFieldOfView) * Double.pi / 180
            let tFOV = Double(tele.activeFormat.videoFieldOfView) * Double.pi / 180
            let denom = tan(tFOV / 2)
            var mult: CGFloat = 2
            if denom > 0.01 {
                mult = CGFloat((tan(wFOV / 2) / denom * 2).rounded() / 2)
            }
            base[.backTele] = max(mult, 2)
        }
        lensBase = base

        // 0.5 / 1 / 2 / 5：每一档选「倍率不超过它」里最长的镜头，剩下的用数码变焦补
        var stops: [ZoomStop] = []
        let backSpecs: [LensSpec] = [.backUltra, .backWide, .backTele]
        for target in [CGFloat(0.5), 1, 2, 5] {
            var best: LensSpec? = nil
            for spec in backSpecs {
                guard let b = base[spec], b <= target + 0.01, device(spec) != nil,
                      found.contains(where: { $0.a == spec }) else { continue }
                if best == nil || b > (base[best!] ?? 0) { best = spec }
            }
            guard let spec = best, let b = base[spec] else { continue }
            let z = max(target / b, 1)
            guard z <= (maxZoom[spec] ?? 1) + 0.001 else { continue }
            stops.append(ZoomStop(value: target, spec: spec, zoom: z))
        }

        currentCombo = first
        DispatchQueue.main.async {
            self.combos = found
            self.comboIndex = 0
            self.zoomStops = stops
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
        // Discard delayed device writes from the previous camera graph.
        deviceConfigGeneration &+= 1
        pendingDeviceUpdateTokens.removeAll()
        pendingDeviceUpdateBodies.removeAll()
        lastDeviceUpdateAt.removeAll()
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
            out.setSampleBufferDelegate(self, queue: i == 0 ? videoQueue : videoQueueB)
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
                // Prefer the native standard stabilizer on each capture connection.
                // MultiCam/device format combinations may not support stabilization; keep that check.
                conn.preferredVideoStabilizationMode = snapshot().stabilization ? .standard : .off
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

        if (session.hardwareCost > 1.0 || session.systemPressureCost > 1.0) && attempt + 1 < heights.count {
            rebuild(attempt: attempt + 1, resetStates: resetStates)
            return
        }

        lock.lock()
        slotFront = [specs[0] == .front, specs[1] == .front]
        latest = [nil, nil]
        bufferSizes = [.zero, .zero]
        sharedFPS = usedFPS
        lock.unlock()

        session.startRunning()
        restartCount = 0
        let running = session.isRunning
        DispatchQueue.main.async {
            self.slotInfos = infos
            self.effectiveFPS = usedFPS
            self.ready = running
            self.statusText = running ? "双摄已启动" : "相机未能启动"
            if resetStates { self.slotStates = [SlotState(), SlotState()] }
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
        let ports = micInput.ports(for: .audio, sourceDeviceType: mic.deviceType, sourceDevicePosition: .unspecified)
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
        if let b = lensBase[spec] { info.baseMultiplier = b }
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
                conn.preferredVideoStabilizationMode = c.stabilization ? .standard : .off
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
        if on && !sharedThumbs {
            // Generate the filter strip once when the panel opens.
            thumbsNeedRefresh = true
        } else if !on {
            thumbsNeedRefresh = false
        }
        sharedThumbs = on
        lock.unlock()
    }

    /// Atomically claim one thumbnail-generation request.
    private func beginThumbs() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard sharedThumbs, thumbsNeedRefresh, !thumbsBusy else { return false }
        thumbsBusy = true
        thumbsNeedRefresh = false
        return true
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
        // 连接已设为竖屏；如果系统没有旋转，兜底转正
        if image.extent.width > image.extent.height { return image.oriented(.right) }
        return image
    }

    private func processFrame(_ pts: CMTime) {
        lock.lock()
        let c = sharedCfg
        let a = latest[0]
        let b = latest[1]
        let front = slotFront
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

        lock.lock()
        let canvasChanged = canvas != lastCanvas
        if canvasChanged { lastCanvas = canvas }
        lock.unlock()
        if canvasChanged {
            let label = "\(Int(canvas.width))×\(Int(canvas.height))"
            DispatchQueue.main.async { self.outputLabel = label }
        }

        // 录像
        recLock.lock()
        let rec = recorder
        let live = liveComposite
        recLock.unlock()
        rec?.appendComposite(finalImage, context: ciContext, time: pts)
        live?.appendComposite(finalImage, context: ciContext, time: pts)

        // 预览：GPU 直接渲染进像素缓冲，立即送显示层（无 CPU 回读、无主线程中转）
        let scale = min(1, 1280 / max(canvas.width, canvas.height))
        let pw = max(2, ((canvas.width * scale) / 2).rounded() * 2)
        let ph = max(2, ((canvas.height * scale) / 2).rounded() * 2)
        let previewImage = finalImage.transformed(by: CGAffineTransform(scaleX: pw / canvas.width,
                                                                        y: ph / canvas.height))
        if let buffer = renderPreviewBuffer(previewImage, width: Int(pw), height: Int(ph)) {
            display(buffer)
        }

        // 滤镜缩略图：每次打开面板只渲染一批，不再每隔 0.7 秒重复计算全部滤镜。
        if beginThumbs() {
            thumbQueue.async { [weak self] in
                guard let self = self else { return }
                self.makeThumbnails(from: composed, canvas: canvas)
                self.endThumbs()
            }
        }
    }

    // MARK: 预览显示

    private func rebuildPreviewPool(width: Int, height: Int) {
        var pool: CVPixelBufferPool?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 4]
        CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, attrs as CFDictionary, &pool)
        previewPool = pool
        previewPoolSize = CGSize(width: width, height: height)
    }

    private func renderPreviewBuffer(_ image: CIImage, width: Int, height: Int) -> CVPixelBuffer? {
        if previewPool == nil || previewPoolSize != CGSize(width: width, height: height) {
            rebuildPreviewPool(width: width, height: height)
        }
        guard let pool = previewPool else { return nil }
        var pb: CVPixelBuffer?
        // 池上限 6 个：显示积压时直接丢这一帧，不让缓冲无限增长拖慢管线。
        let limits: [String: Any] = [kCVPixelBufferPoolAllocationThresholdKey as String: 6]
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault, pool, limits as CFDictionary, &pb
        ) == kCVReturnSuccess, let out = pb else { return nil }
        ciContext.render(image, to: out,
                         bounds: CGRect(x: 0, y: 0, width: width, height: height),
                         colorSpace: srgb)
        return out
    }

    /// 立即显示（不排队、不等时间戳）。必须在 videoQueue 上调用。
    private func display(_ pixelBuffer: CVPixelBuffer) {
        if displayLayer.status == .failed { displayLayer.flush() }
        guard displayLayer.isReadyForMoreMediaData else { return }

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        if displayFormat == nil || displayFormatSize != size {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &format)
            displayFormat = format
            displayFormatSize = size
        }
        guard let format = displayFormat else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                 formatDescription: format, sampleTiming: &timing,
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

    private func endThumbs() {
        lock.lock()
        thumbsBusy = false
        lock.unlock()
    }

    private func makeThumbnails(from image: CIImage, canvas: CGSize) {
        let tw: CGFloat = 120
        let th = max(2, (tw * canvas.height / canvas.width).rounded())
        let small = image.transformed(by: CGAffineTransform(scaleX: tw / canvas.width, y: th / canvas.height))
        let rect = CGRect(x: 0, y: 0, width: tw, height: th)
        var result: [String: UIImage] = [:]
        for kind in FilterKind.allCases {
            let out = kind.apply(to: small, intensity: 1).cropped(to: rect)
            if let cg = thumbContext.createCGImage(out, from: rect, format: .RGBA8, colorSpace: srgb) {
                result[kind.rawValue] = UIImage(cgImage: cg)
            }
        }
        DispatchQueue.main.async { self.filterThumbs = result }
    }

    // MARK: - 变焦 / 参数

    /// 点 0.5 / 1 / 2 / 5：同一颗镜头只改变焦，换镜头则重建会话。
    func selectStop(_ stop: ZoomStop) {
        guard comboIndex < combos.count else { return }
        let current = combos[comboIndex]
        if current.a == stop.spec {
            setZoom(slot: 0, factor: stop.zoom)
            return
        }
        guard !isRecording else {
            showToast("录像中不能切换镜头，请先停止录像")
            return
        }
        var target = combos.firstIndex(where: { $0.a == stop.spec && $0.b == current.b })
        if target == nil { target = combos.firstIndex(where: { $0.a == stop.spec && $0.b == .front }) }
        if target == nil { target = combos.firstIndex(where: { $0.a == stop.spec }) }
        guard let idx = target else { return }
        comboIndex = idx
        let combo = combos[idx]
        slotStates[0] = SlotState(zoom: stop.zoom)
        if combo.b != current.b { slotStates[1] = SlotState() }
        ready = false
        sessionQueue.async {
            self.currentCombo = combo
            self.rebuild(resetStates: false)
        }
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

    /// Coalesce rapid slider updates so only the newest parameter value reaches the device.
    private func withDeviceCoalesced(
        _ slot: Int,
        key: String,
        minimumInterval: TimeInterval = 1.0 / 30.0,
        _ body: @escaping (AVCaptureDevice) -> Void
    ) {
        sessionQueue.async { [weak self] in
            guard let self = self, slot < self.devices.count,
                  self.devices[slot] != nil else { return }
            let updateKey = "\(slot):\(key)"
            let generation = self.deviceConfigGeneration
            self.pendingDeviceUpdateBodies[updateKey] = body

            let now = DispatchTime.now().uptimeNanoseconds
            let intervalNanos = UInt64(max(minimumInterval, 0.001) * 1_000_000_000)
            let last = self.lastDeviceUpdateAt[updateKey] ?? 0
            if last == 0 || now >= last + intervalNanos {
                self.pendingDeviceUpdateTokens.removeValue(forKey: updateKey)
                let newest = self.pendingDeviceUpdateBodies.removeValue(forKey: updateKey) ?? body
                self.performDeviceUpdate(slot, key: updateKey, body: newest)
                return
            }

            guard self.pendingDeviceUpdateTokens[updateKey] == nil else { return }
            let token = UUID()
            self.pendingDeviceUpdateTokens[updateKey] = token
            let waitNanos = max(1, last + intervalNanos - now)
            self.sessionQueue.asyncAfter(deadline: .now() + Double(waitNanos) / 1_000_000_000) { [weak self] in
                guard let self = self,
                      self.deviceConfigGeneration == generation,
                      self.pendingDeviceUpdateTokens[updateKey] == token else { return }
                self.pendingDeviceUpdateTokens.removeValue(forKey: updateKey)
                guard let newest = self.pendingDeviceUpdateBodies.removeValue(forKey: updateKey) else { return }
                self.performDeviceUpdate(slot, key: updateKey, body: newest)
            }
        }
    }

    private func performDeviceUpdate(_ slot: Int, key: String, body: (AVCaptureDevice) -> Void) {
        guard slot < devices.count, let device = devices[slot] else { return }
        do { try device.lockForConfiguration() } catch { return }
        body(device)
        device.unlockForConfiguration()
        lastDeviceUpdateAt[key] = DispatchTime.now().uptimeNanoseconds
    }

    func applyZoom(_ slot: Int) {
        let z = slotStates[slot].zoom
        withDeviceCoalesced(slot, key: "zoom", minimumInterval: 1.0 / 60.0) { d in
            d.videoZoomFactor = min(max(z, 1), d.activeFormat.videoMaxZoomFactor)
        }
    }

    func applyFocus(_ slot: Int) {
        let s = slotStates[slot]
        withDeviceCoalesced(slot, key: "focus") { d in
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
        withDeviceCoalesced(slot, key: "exposure") { d in
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
        withDeviceCoalesced(slot, key: "white-balance") { d in
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

    /// Copy the selected camera's white-balance settings to the other camera.
    /// This can reduce color-temperature mismatch in dual-camera layouts.
    func copyWhiteBalanceToOtherSlot(_ slot: Int) {
        guard slotStates.indices.contains(slot), slotStates.count >= 2 else { return }
        let other = slot == 0 ? 1 : 0
        let source = slotStates[slot]
        slotStates[other].manualWB = source.manualWB
        slotStates[other].temperature = source.temperature
        slotStates[other].tint = source.tint
        applyWhiteBalance(other)
        toast = "已同步白平衡"
    }

    func toggleLock(_ slot: Int) {
        guard slotStates.indices.contains(slot) else { return }
        slotStates[slot].locked.toggle()
        applyFocus(slot)
        applyExposure(slot)
    }

    func resetExposureBias(_ slot: Int) {
        guard slotStates.indices.contains(slot) else { return }
        slotStates[slot].exposureBias = 0
        applyExposure(slot)
    }

    func setAutoFocus(_ slot: Int) {
        guard slotStates.indices.contains(slot) else { return }
        slotStates[slot].manualFocus = false
        slotStates[slot].locked = false
        applyFocus(slot)
        applyExposure(slot)
    }

    /// Apply filter controls as one config transaction, only after the user confirms.
    func applyFilter(_ kind: FilterKind, intensity: CGFloat) {
        var next = cfg
        next.filter = kind
        next.filterIntensity = intensity.isFinite ? min(max(intensity, 0), 1) : 1
        cfg = next
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
        showMarker(at: p, slot: slot)
    }

    func showMarker(at p: CGPoint, slot: Int? = nil) {
        exposureMarkerID = nil
        let marker = FocusMarker(point: p, slot: slot)
        focusMarker = marker
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            if self.focusMarker?.id == marker.id { self.focusMarker = nil }
        }
    }

    private func showExposureMarker(at p: CGPoint, bias: Float, slot: Int) {
        let isFirst = exposureMarkerID == nil
        let id = exposureMarkerID ?? focusMarker?.id ?? UUID()
        exposureMarkerID = id
        focusMarker = FocusMarker(point: p, exposureBias: bias, slot: slot, id: id)
        if isFirst {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self = self, self.focusMarker?.id == id else { return }
                self.focusMarker = nil
                self.exposureMarkerID = nil
            }
        }
    }

    /// 预览画面中的独立曝光滑杆回调。
    func adjustExposureBias(slot: Int, value: Float) {
        guard slotStates.indices.contains(slot) else { return }
        let state = slotStates[slot]
        guard !state.manualExposure, !state.locked else { return }
        let info = slotInfos[slot]
        let bias = min(max(value, info.minBias), info.maxBias)
        slotStates[slot].exposureBias = bias
        applyExposure(slot)
        let point = focusMarker?.point ?? CGPoint(x: 0.5, y: 0.5)
        showExposureMarker(at: point, bias: bias, slot: slot)
    }

    func exposureDragBegan(at p: CGPoint) {
        let c = cfg
        let regions = Compositor.regions(cfg: c)
        let mainSlot = c.swapped ? 1 : 0
        dragSlot = regions.sub.contains(p) ? 1 - mainSlot : mainSlot
        dragStartBias = slotStates[dragSlot].exposureBias
    }

    func exposureDragChanged(dy: CGFloat, at point: CGPoint) {
        let slot = dragSlot
        let s = slotStates[slot]
        guard !s.manualExposure, !s.locked else { return }
        let info = slotInfos[slot]
        let bias = min(max(dragStartBias - Float(dy / 70), info.minBias), info.maxBias)
        slotStates[slot].exposureBias = bias
        applyExposure(slot)
        let markerPoint = focusMarker?.point ?? point
        showExposureMarker(at: markerPoint, bias: bias, slot: slot)
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
        guard combos.count > 1 else { return }
        selectCombo((comboIndex + 1) % combos.count)
    }

    func selectCombo(_ index: Int) {
        guard !isRecording, combos.indices.contains(index), index != comboIndex else { return }
        comboIndex = index
        let combo = combos[index]
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
        let sizes = bufferSizes
        let fps = sharedFPS
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

        // 原图直出：每颗镜头各存一张未镜像、未加滤镜、未裁切、未合成的画面；合成图是预览里看到的样子
        var shots: [StillShot] = []
        if c.outputMode.savesComposite { shots.append(StillShot(image: finalImage, slot: nil)) }
        if c.outputMode.savesOriginal {
            shots.append(StillShot(image: rawA, slot: 0))
            if let rb = rawB { shots.append(StillShot(image: rb, slot: 1)) }
        }
        guard !shots.isEmpty else {
            showToast("生成照片失败")
            return
        }

        // 实况：每张照片配一段 1.6 秒的短视频，写入前先准备好录制器
        if c.livePhoto {
            for i in shots.indices {
                let size = shots[i].slot.map { sizes[$0] } ?? canvas
                guard size.width > 0 else { continue }
                let id = UUID().uuidString
                if let rec = try? VideoRecorder(width: Int(size.width), height: Int(size.height), fps: fps,
                                                audioSettings: nil, liveID: id),
                   rec.start() {
                    shots[i].liveID = id
                    shots[i].recorder = rec
                }
            }
        }

        // 照片编码（实况照片要把同一个 ID 写进 JPEG）
        for i in shots.indices {
            if let id = shots[i].liveID {
                if let d = jpegWithIdentifier(shots[i].image, id: id) {
                    shots[i].data = d
                } else {
                    // 编码失败就退回普通照片，并丢弃配套视频
                    shots[i].recorder?.finish { _ in }
                    shots[i].recorder = nil
                    shots[i].liveID = nil
                    shots[i].data = jpeg(shots[i].image)
                }
            } else {
                shots[i].data = jpeg(shots[i].image)
            }
        }

        guard shots.contains(where: { $0.recorder != nil }) else {
            let datas = shots.compactMap { $0.data }
            guard !datas.isEmpty else {
                showToast("生成照片失败")
                return
            }
            saveImages(datas)
            return
        }

        recLock.lock()
        for s in shots {
            guard let rec = s.recorder else { continue }
            if let slot = s.slot { liveRaw[slot] = rec } else { liveComposite = rec }
        }
        recLock.unlock()

        let finished = shots
        videoQueue.asyncAfter(deadline: .now() + liveSeconds) { [weak self] in
            self?.finishLive(finished)
        }
    }

    private func finishLive(_ shots: [StillShot]) {
        recLock.lock()
        liveComposite = nil
        liveRaw = [nil, nil]
        recLock.unlock()

        let box = MovieSlots(count: shots.count)
        let group = DispatchGroup()
        for (i, s) in shots.enumerated() {
            guard let rec = s.recorder else { continue }
            group.enter()
            rec.finish { url in
                box.set(i, url)
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            var items: [SavedItem] = []
            for (i, s) in shots.enumerated() {
                if let d = s.data { items.append(SavedItem(photo: d, movie: box.get(i))) }
            }
            self?.saveLivePhotos(items)
        }
    }

    private func jpeg(_ image: CIImage) -> Data? {
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: image, colorSpace: srgb, options: [key: 0.95])
    }

    /// 实况照片的静态图：JPEG 的 Apple MakerNote 里写入与视频相同的 content identifier。
    private func jpegWithIdentifier(_ image: CIImage, id: String) -> Data? {
        guard let cg = ciContext.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: srgb) else {
            return nil
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
            return nil
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyMakerAppleDictionary: ["17": id]
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func setThumb(data: Data) {
        guard let img = UIImage(data: data) else { return }
        let thumb = img.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? img
        DispatchQueue.main.async { self.lastThumb = thumb }
    }

    private func saveLivePhotos(_ items: [SavedItem]) {
        guard !items.isEmpty else { return }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
            guard let self = self else { return }
            guard status == .authorized || status == .limited else {
                for item in items { if let m = item.movie { try? FileManager.default.removeItem(at: m) } }
                self.showToast("请在「设置」中允许保存到照片")
                return
            }
            // 配对资源必须是文件
            let photoURLs: [URL?] = items.map { item in
                guard item.movie != nil else { return nil }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("dualcam-\(UUID().uuidString).jpg")
                return (try? item.photo.write(to: url)) != nil ? url : nil
            }
            PHPhotoLibrary.shared().performChanges({
                for (i, item) in items.enumerated() {
                    let req = PHAssetCreationRequest.forAsset()
                    if let movie = item.movie, let jpg = photoURLs[i] {
                        req.addResource(with: .photo, fileURL: jpg, options: nil)
                        req.addResource(with: .pairedVideo, fileURL: movie, options: nil)
                    } else {
                        req.addResource(with: .photo, data: item.photo, options: nil)
                    }
                }
            }, completionHandler: { ok, error in
                for (i, item) in items.enumerated() {
                    if let m = item.movie { try? FileManager.default.removeItem(at: m) }
                    if let p = photoURLs[i] { try? FileManager.default.removeItem(at: p) }
                }
                self.showToast(ok ? "实况照片已保存（\(items.count) 张）" : "保存失败：\(error?.localizedDescription ?? "未知错误")")
            })
            if let first = items.first { self.setThumb(data: first.photo) }
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
                self.showToast(ok ? "照片已保存（\(datas.count) 张）" : "保存失败：\(error?.localizedDescription ?? "未知错误")")
            })
            if let first = datas.first { self.setThumb(data: first) }
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
                // 合成视频：预览里看到的样子；原图直出：每颗镜头各录一份原始画面（各自带音轨）
                var comp: VideoRecorder? = nil
                if c.outputMode.savesComposite {
                    let r = try VideoRecorder(width: Int(canvas.width), height: Int(canvas.height), fps: fps, audioSettings: audioSettings)
                    guard r.start() else {
                        self.showToast("无法开始录像")
                        return
                    }
                    comp = r
                }
                var raws: [VideoRecorder?] = [nil, nil]
                if c.outputMode.savesOriginal {
                    for i in 0..<2 where sizes[i].width > 0 {
                        if let r = try? VideoRecorder(width: Int(sizes[i].width), height: Int(sizes[i].height), fps: fps, audioSettings: audioSettings),
                           r.start() {
                            raws[i] = r
                        }
                    }
                }
                guard comp != nil || raws.contains(where: { $0 != nil }) else {
                    self.showToast("无法开始录像")
                    return
                }
                self.recLock.lock()
                self.recorder = comp
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
            // 缩略图取视频第一帧
            let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 320, height: 320)
            if let cg = try? gen.copyCGImage(at: .zero, actualTime: nil) {
                let thumb = UIImage(cgImage: cg)
                DispatchQueue.main.async { self.lastThumb = thumb }
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
            let raws = rawRecorders
            recLock.unlock()
            rec?.appendAudio(sampleBuffer)
            for r in raws { r?.appendAudio(sampleBuffer) }
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
        let liveRawRec = liveRaw[slot]
        recLock.unlock()
        raw?.appendRaw(pixel, time: pts)
        liveRawRec?.appendRaw(pixel, time: pts)

        if slot == 0 { processFrame(pts) }
    }
}

// MARK: - 拍照辅助类型

/// 一张要保存的照片：原图（某个镜头）或合成图，以及它的实况配套录制器。
private struct StillShot {
    var image: CIImage
    var slot: Int?                 // nil = 合成图；0 / 1 = 对应镜头的原图
    var liveID: String? = nil
    var recorder: VideoRecorder? = nil
    var data: Data? = nil
}

private struct SavedItem {
    let photo: Data
    let movie: URL?
}

/// 多个录制器的完成回调在不同线程，用它收集各自的输出文件。
private final class MovieSlots {
    private var urls: [URL?]
    private let lock = NSLock()

    init(count: Int) {
        urls = [URL?](repeating: nil, count: count)
    }

    func set(_ index: Int, _ url: URL?) {
        lock.lock()
        urls[index] = url
        lock.unlock()
    }

    func get(_ index: Int) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls[index]
    }
}
