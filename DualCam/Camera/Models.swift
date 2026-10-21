import AVFoundation
import SwiftUI

enum LayoutMode: String, CaseIterable, Identifiable {
    case pip = "画中画"
    case split = "上下分屏"
    var id: String { rawValue }
}

enum PiPShape: String, CaseIterable, Identifiable {
    case rounded = "圆角"
    case circle = "圆形"
    var id: String { rawValue }
}

enum PiPRatio: String, CaseIterable, Identifiable {
    case r34 = "3:4"
    case r11 = "1:1"
    case r43 = "4:3"
    case r916 = "9:16"
    var id: String { rawValue }
    /// 宽 / 高
    var value: CGFloat {
        switch self {
        case .r34: return 3.0 / 4.0
        case .r11: return 1.0
        case .r43: return 4.0 / 3.0
        case .r916: return 9.0 / 16.0
        }
    }
}

enum CanvasAspect: String, CaseIterable, Identifiable {
    case r916 = "9:16"
    case r34 = "3:4"
    case r11 = "1:1"
    var id: String { rawValue }
    /// 宽 / 高
    var value: CGFloat {
        switch self {
        case .r916: return 9.0 / 16.0
        case .r34: return 3.0 / 4.0
        case .r11: return 1.0
        }
    }
}

enum ResolutionOption: String, CaseIterable, Identifiable {
    case p720 = "720p"
    case p1080 = "1080p"
    case maximum = "最高"
    var id: String { rawValue }
}

enum CaptureMode: String {
    case photo = "拍照"
    case video = "录像"
}

/// 照片 / 视频保存什么。
/// - original：每颗镜头各存一份原始画面（不镜像、不加滤镜、不裁切、不合成）
/// - composite：只存预览里看到的合成画面（画中画 / 分屏 + 滤镜）
/// - both：两者都存
enum OutputMode: String, CaseIterable, Identifiable {
    case original = "原图直出"
    case composite = "合成画面"
    case both = "两者都存"
    var id: String { rawValue }
    var savesOriginal: Bool { self != .composite }
    var savesComposite: Bool { self != .original }
}

enum PanelTab: String, CaseIterable, Identifiable {
    case pip = "小窗"
    case filter = "滤镜"
    case params = "参数"
    case settings = "设置"
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .pip: return "pip"
        case .filter: return "camera.filters"
        case .params: return "slider.horizontal.3"
        case .settings: return "gearshape"
        }
    }
}

/// 所有会影响合成画面和采集的设置。UI 修改它，渲染线程读取它的快照。
struct Config: Equatable {
    // 布局
    var layout: LayoutMode = .pip
    var swapped = false
    var aspect: CanvasAspect = .r34
    var pipCenter = CGPoint(x: 0.76, y: 0.20)   // 归一化，左上角为原点
    var pipWidth: CGFloat = 0.32                // 占画布宽度的比例
    var pipRatio: PiPRatio = .r34
    var pipShape: PiPShape = .rounded
    var pipCorner: CGFloat = 0.14               // 0...0.5，占小窗短边的比例
    var pipBorder: CGFloat = 2                  // 0...8，按 390 宽的预览换算
    var pipOpacity: CGFloat = 1
    var pipSnap = true
    var splitRatio: CGFloat = 0.5               // 上半部分占比
    var mirrorFront = true
    // 滤镜
    var filter: FilterKind = .original
    var filterIntensity: CGFloat = 1
    // 采集
    var resolution: ResolutionOption = .p1080
    var fps = 30
    var outputMode: OutputMode = .original
    var livePhoto = true
    var lowLight = true
    var stabilization = false   // 默认关闭：防抖会让预览多延迟几帧
    var showGrid = true
}

/// 每个镜头（A / B 两个槽位）各自记住的参数。
struct SlotState: Equatable {
    var zoom: CGFloat = 1                // 设备 videoZoomFactor
    var exposureBias: Float = 0
    var manualExposure = false
    var iso: Float = 100
    var shutter: Double = 0.5            // 0...1，对数刻度
    var manualWB = false
    var temperature: Float = 5200
    var tint: Float = 0
    var manualFocus = false
    var lensPosition: Float = 0.5
    var locked = false
}

/// 镜头能力信息，在会话建立后由后台线程填好。
struct SlotInfo: Equatable {
    var name = "—"
    var isFront = false
    var baseMultiplier: CGFloat = 1      // 显示倍率 = zoom * baseMultiplier
    var maxZoom: CGFloat = 1
    var minISO: Float = 25
    var maxISO: Float = 1600
    var minBias: Float = -4
    var maxBias: Float = 4
    var minShutter: Double = 1.0 / 8000.0
    var maxShutter: Double = 1.0 / 30.0
    var hasTorch = false
    var supportsManualFocus = false
}

enum LensSpec: String {
    case backWide, backUltra, backTele, front

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .backWide, .front: return .builtInWideAngleCamera
        case .backUltra: return .builtInUltraWideCamera
        case .backTele: return .builtInTelephotoCamera
        }
    }

    var position: AVCaptureDevice.Position {
        return self == .front ? .front : .back
    }

    var title: String {
        switch self {
        case .backWide: return "后置广角"
        case .backUltra: return "后置超广角"
        case .backTele: return "后置长焦"
        case .front: return "前置"
        }
    }

    var shortTitle: String {
        switch self {
        case .backWide: return "后广"
        case .backUltra: return "后超广"
        case .backTele: return "后长焦"
        case .front: return "前置"
        }
    }
}

struct LensCombo: Equatable {
    var a: LensSpec
    var b: LensSpec
    var title: String { "\(a.shortTitle)+\(b.shortTitle)" }
}

/// 焦段快捷档（0.5 / 1 / 2 / 5）。点一档就切到对应镜头并设置好变焦倍率。
struct ZoomStop: Equatable, Identifiable {
    let value: CGFloat      // 显示倍率：0.5 / 1 / 2 / 5
    let spec: LensSpec      // 该档使用的后置镜头
    let zoom: CGFloat       // 该镜头上的 videoZoomFactor
    var id: CGFloat { value }
}

struct FocusMarker: Equatable {
    let id = UUID()
    var point: CGPoint   // 归一化，相对预览区域
}
