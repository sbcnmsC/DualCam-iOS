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

    var id: String { rawValue }

    /// 对合成后的整幅画面应用滤镜。intensity 为 0...1，1 为完全应用。
    func apply(to image: CIImage, intensity: CGFloat) -> CIImage {
        guard self != .original else { return image }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.isInfinite == false else { return image }
        let t = intensity.isFinite ? min(max(intensity, 0), 1) : 1
        guard t > 0.001 else { return image }

        // Keep Core Image effects inside the original frame to prevent edge expansion.
        let filtered = rawApply(image).cropped(to: extent)
        if t >= 0.999 { return filtered }
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
            // Favor vibrance over global saturation to protect skin and bright colors.
            let v = image.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.32])
            return colorControls(v, saturation: 1.08, brightness: 0, contrast: 1.035)
        case .warm:
            let m = colorMatrix(image, r: 1.035, g: 1.005, b: 0.965)
            return colorControls(m, saturation: 1.02, brightness: 0.005, contrast: 1.015)
        case .cool:
            let m = colorMatrix(image, r: 0.97, g: 1.0, b: 1.035)
            return colorControls(m, saturation: 0.99, brightness: 0, contrast: 1.02)
        case .fresh:
            let c = colorControls(image, saturation: 1.07, brightness: 0.015, contrast: 0.98)
            return colorMatrix(c, r: 0.99, g: 1.02, b: 1.02)
        case .cinema:
            let c = colorControls(image, saturation: 0.91, brightness: -0.005, contrast: 1.08)
            return colorMatrix(c, r: 1.025, g: 1.005, b: 0.98)
        case .film:
            let c = colorControls(image, saturation: 0.91, brightness: 0, contrast: 1.045)
            return colorMatrix(c, r: 1.025, g: 1.0, b: 0.975, bias: CIVector(x: 0.008, y: 0.005, z: 0.003, w: 0))
        case .retro:
            let s = image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.32])
            return colorControls(s, saturation: 0.98, brightness: 0, contrast: 1.025)
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
            return colorControls(m, saturation: 1.0, brightness: -0.01, contrast: 1.15)
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
