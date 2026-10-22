import CoreGraphics
import CoreImage
import Foundation

/// 把两路画面合成为一幅（画中画 / 上下分屏）。预览、拍照、录像共用同一套逻辑，保证所见即所得。
enum Compositor {

    // MARK: - 尺寸

    /// forStill：兼容路径（实况 / 回退）的照片画布可以比录像大——单帧编码 JPEG 不受实时编码器限制，
    /// 「最高」档直接用摄像头全部像素；录像和预览合成仍封顶 4K 级，避免实时 HEVC 编码跟不上。
    static func canvasSize(aspect: CanvasAspect, resolution: ResolutionOption, sourceWidth: CGFloat,
                           aspectRatio: CGFloat? = nil, forStill: Bool = false) -> CGSize {
        var w: CGFloat
        switch resolution {
        case .p720: w = 720
        case .p1080: w = 1080
        case .maximum: w = min(max(sourceWidth, 720), forStill ? 4032 : 2160)
        }
        // 不超过摄像头实际像素，不做无意义的放大
        if sourceWidth >= 360 { w = min(w, sourceWidth) }
        w = floor(w / 2) * 2
        let ratio = max(aspectRatio ?? aspect.value, 0.1)
        let h = (w / ratio / 2).rounded() * 2
        return CGSize(width: w, height: h)
    }

    // MARK: - 区域（归一化，左上角为原点）

    /// 小窗矩形。圆形强制 1:1，并保证整体落在画布内。
    static func pipRectNormalized(cfg: Config) -> CGRect {
        let ratio: CGFloat = cfg.pipShape == .circle ? 1 : cfg.pipRatio.value
        let canvasAspect = cfg.aspectRatio
        var w = min(max(cfg.pipWidth, 0.1), 0.95)
        var h = w * canvasAspect / ratio
        if h > 0.95 {
            let k = 0.95 / h
            w *= k
            h *= k
        }
        let cx = min(max(cfg.pipCenter.x, w / 2), 1 - w / 2)
        let cy = min(max(cfg.pipCenter.y, h / 2), 1 - h / 2)
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// 主画面和副画面各自占据的区域。
    static func regions(cfg: Config) -> (main: CGRect, sub: CGRect) {
        switch cfg.layout {
        case .pip:
            return (CGRect(x: 0, y: 0, width: 1, height: 1), pipRectNormalized(cfg: cfg))
        case .split:
            let r = min(max(cfg.splitRatio, 0.2), 0.8)
            return (CGRect(x: 0, y: 0, width: 1, height: r),
                    CGRect(x: 0, y: r, width: 1, height: 1 - r))
        }
    }

    /// 把预览上的点按位置换算为摄像头的对焦 / 测光坐标（传感器横向坐标系，0...1）。
    static func devicePoint(
        tap: CGPoint, region: CGRect, canvas: CGSize, bufferSize: CGSize, mirrored: Bool,
        landscape: Bool = false, reverseLandscape: Bool = false
    ) -> CGPoint {
        let rw = region.width * canvas.width
        let rh = region.height * canvas.height
        // Buffer sizes are stored in portrait-normalized form; swap them back in landscape.
        let orientedSize = landscape
            ? CGSize(width: bufferSize.height, height: bufferSize.width)
            : bufferSize
        guard rw > 0, rh > 0, orientedSize.width > 0, orientedSize.height > 0 else {
            return CGPoint(x: 0.5, y: 0.5)
        }
        let s = max(rw / orientedSize.width, rh / orientedSize.height)
        let lx = (tap.x - region.minX) * canvas.width - rw / 2
        let ly = (tap.y - region.minY) * canvas.height - rh / 2
        var nx = (orientedSize.width / 2 + lx / s) / orientedSize.width
        let ny = (orientedSize.height / 2 + ly / s) / orientedSize.height
        if mirrored { nx = 1 - nx }
        if landscape {
            let x = reverseLandscape ? 1 - nx : nx
            let y = reverseLandscape ? 1 - ny : ny
            return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        }
        // Portrait view maps back to the camera's native landscape sensor coordinates.
        return CGPoint(x: min(max(ny, 0), 1), y: min(max(1 - nx, 0), 1))
    }

    // MARK: - 合成

    /// main / sub 已经是竖屏方向（必要时已做镜像）。返回范围恰好为 canvas 的图像。
    static func compose(main: CIImage, sub: CIImage?, cfg: Config, canvas: CGSize) -> CIImage {
        let W = canvas.width
        let H = canvas.height
        let full = CGRect(x: 0, y: 0, width: W, height: H)

        switch cfg.layout {
        case .pip:
            let base = fill(main, into: full)
            guard let sub = sub else { return base.cropped(to: full) }
            let n = pipRectNormalized(cfg: cfg)
            let rect = CGRect(x: (n.minX * W).rounded(),
                              y: (H - n.maxY * H).rounded(),
                              width: (n.width * W).rounded(),
                              height: (n.height * H).rounded())
            guard rect.width >= 2, rect.height >= 2 else { return base.cropped(to: full) }

            var small = fill(sub, into: rect)
            if let mask = shapeImage(size: rect.size, shape: cfg.pipShape, corner: cfg.pipCorner, stroke: 0, fillShape: true) {
                let placed = mask.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                small = small.applyingFilter("CISourceInCompositing", parameters: [
                    kCIInputBackgroundImageKey: placed
                ])
            }
            if cfg.pipOpacity < 0.995 {
                small = small.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: cfg.pipOpacity)
                ])
            }
            var out = small.composited(over: base)
            let borderPx = cfg.pipBorder / 390.0 * W
            if borderPx >= 0.5,
               let ring = shapeImage(size: rect.size, shape: cfg.pipShape, corner: cfg.pipCorner, stroke: borderPx, fillShape: false) {
                let placed = ring.transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
                out = placed.composited(over: out)
            }
            return out.cropped(to: full)

        case .split:
            let r = min(max(cfg.splitRatio, 0.2), 0.8)
            let topH = (H * r / 2).rounded() * 2
            let topRect = CGRect(x: 0, y: H - topH, width: W, height: topH)
            let bottomRect = CGRect(x: 0, y: 0, width: W, height: H - topH)
            let top = fill(main, into: topRect)
            let bottom: CIImage
            if let sub = sub {
                bottom = fill(sub, into: bottomRect)
            } else {
                bottom = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: bottomRect)
            }
            return top.composited(over: bottom).cropped(to: full)
        }
    }

    /// 等比缩放到刚好覆盖 rect（CI 坐标，左下角为原点），居中并裁剪到 rect。
    static func fill(_ image: CIImage, into rect: CGRect) -> CIImage {
        let e = image.extent
        guard e.width > 0, e.height > 0, !e.isInfinite else { return image.cropped(to: rect) }
        let s = max(rect.width / e.width, rect.height / e.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let se = scaled.extent
        let moved = scaled.transformed(by: CGAffineTransform(translationX: rect.midX - se.midX,
                                                              y: rect.midY - se.midY))
        return moved.cropped(to: rect)
    }

    // MARK: - 小窗形状

    private static let cacheLock = NSLock()
    private static var cache: [String: CIImage] = [:]

    private static func shapeImage(size: CGSize, shape: PiPShape, corner: CGFloat, stroke: CGFloat, fillShape: Bool) -> CIImage? {
        let w = Int(size.width)
        let h = Int(size.height)
        guard w > 1, h > 1 else { return nil }
        let key = "\(w)x\(h)-\(shape.rawValue)-\(Int(corner * 1000))-\(Int(stroke * 10))-\(fillShape)"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        let shortSide = CGFloat(min(w, h))
        let radius: CGFloat = shape == .circle ? shortSide / 2 : min(shortSide / 2, shortSide * min(max(corner, 0), 0.5))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        if fillShape {
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        } else {
            let inset = stroke / 2
            let r2 = rect.insetBy(dx: inset, dy: inset)
            let r2Radius = max(0, min(radius - inset, min(r2.width, r2.height) / 2))
            let path = CGPath(roundedRect: r2, cornerWidth: r2Radius, cornerHeight: r2Radius, transform: nil)
            ctx.setLineWidth(stroke)
            ctx.addPath(path)
            ctx.strokePath()
        }
        guard let cg = ctx.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        cacheLock.lock()
        if cache.count > 24 { cache.removeAll() }
        cache[key] = image
        cacheLock.unlock()
        return image
    }
}
