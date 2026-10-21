import CoreImage

enum FilterKind: String, CaseIterable, Identifiable {
    case original = "原片"
    case vivid = "鲜艳"
    case warm = "暖阳"
    case cool = "冷调"
    case fresh = "清新"
    case cinema = "电影"
    case film = "胶片"
    case retro = "复古"
    case faded = "褪色"
    case chrome = "铬黄"
    case mono = "黑白"
    case blackGold = "黑金"
    case beach = "海边"
    case landscape = "风光"
    case humanity = "人文"

    var id: String { rawValue }

    /// 对合成后的整幅画面应用滤镜。intensity 为 0...1，1 为完全应用。
    func apply(to image: CIImage, intensity: CGFloat) -> CIImage {
        if self == .original { return image }
        let extent = image.extent
        // Keep every preset inside the original frame; some Core Image effects can
        // otherwise expand their extent and cause edge artifacts or inconsistent thumbnails.
        let filtered = rawApply(image).cropped(to: extent)
        let t = min(max(intensity.isFinite ? intensity : 1, 0), 1)
        if t >= 0.999 { return filtered }
        if t <= 0.001 { return image }
        return image.applyingFilter("CIDissolveTransition", parameters: [
            kCIInputTargetImageKey: filtered,
            kCIInputTimeKey: t
        ]).cropped(to: extent)
    }

    private func rawApply(_ image: CIImage) -> CIImage {
        switch self {
        case .original:
            return image
        case .vivid:
            let v = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.6])
            return colorControls(v, saturation: 1.22, brightness: 0, contrast: 1.08)
        case .warm:
            let m = colorMatrix(image, r: 1.10, g: 1.02, b: 0.86)
            return colorControls(m, saturation: 1.08, brightness: 0.02, contrast: 1.0)
        case .cool:
            let m = colorMatrix(image, r: 0.90, g: 1.0, b: 1.13)
            return colorControls(m, saturation: 1.0, brightness: 0, contrast: 1.04)
        case .fresh:
            let c = colorControls(image, saturation: 1.12, brightness: 0.07, contrast: 0.94)
            return colorMatrix(c, r: 0.98, g: 1.04, b: 1.04)
        case .cinema:
            let c = colorControls(image, saturation: 0.88, brightness: -0.02, contrast: 1.16)
            return colorMatrix(c, r: 1.06, g: 1.0, b: 0.95)
        case .film:
            let c = colorControls(image, saturation: 0.86, brightness: 0.01, contrast: 1.1)
            return colorMatrix(c, r: 1.05, g: 1.0, b: 0.94, bias: CIVector(x: 0.025, y: 0.02, z: 0.012, w: 0))
        case .retro:
            let s = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.55])
            return colorControls(s, saturation: 0.95, brightness: 0, contrast: 1.05)
        case .faded:
            return image.applyingFilter("CIPhotoEffectFade")
        case .chrome:
            return image.applyingFilter("CIPhotoEffectChrome")
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .blackGold:
            let m = image.applyingFilter("CIColorMonochrome", parameters: [
                kCIInputColorKey: CIColor(red: 1.0, green: 0.80, blue: 0.40),
                kCIInputIntensityKey: 1.0
            ])
            return colorControls(m, saturation: 1.0, brightness: -0.03, contrast: 1.25)
        case .beach:
            // Coastal look: aqua water and open highlights without an extreme cyan cast.
            let balanced = colorMatrix(image, r: 1.015, g: 1.045, b: 1.075,
                                       bias: CIVector(x: 0.006, y: 0.009, z: 0.012, w: 0))
            let vivid = balanced.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.22])
            return colorControls(vivid, saturation: 1.10, brightness: 0.025, contrast: 1.035)
        case .landscape:
            let vivid = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.48])
            return colorControls(vivid, saturation: 1.12, brightness: 0.01, contrast: 1.10)
        case .humanity:
            // Documentary / street portrait look: quieter saturation and a restrained warm bias.
            let balanced = colorMatrix(image, r: 1.035, g: 1.005, b: 0.965,
                                       bias: CIVector(x: 0.012, y: 0.008, z: 0.004, w: 0))
            return colorControls(balanced, saturation: 0.84, brightness: 0.012, contrast: 1.055)
        }
    }
}

fileprivate func colorControls(_ image: CIImage, saturation: CGFloat, brightness: CGFloat, contrast: CGFloat) -> CIImage {
    return image.applyingFilter("CIColorControls", parameters: [
        kCIInputSaturationKey: saturation,
        kCIInputBrightnessKey: brightness,
        kCIInputContrastKey: contrast
    ])
}

fileprivate func colorMatrix(_ image: CIImage, r: CGFloat, g: CGFloat, b: CGFloat,
                             bias: CIVector = CIVector(x: 0, y: 0, z: 0, w: 0)) -> CIImage {
    return image.applyingFilter("CIColorMatrix", parameters: [
        "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
        "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
        "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        "inputBiasVector": bias
    ])
}
