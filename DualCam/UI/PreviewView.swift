import SwiftUI
import AVFoundation
import UIKit

/// 预览直接挂 AVSampleBufferDisplayLayer：和系统相机同一条硬件显示通路，
/// IOSurface 零拷贝，不做 layer.contents = CGImage（避免每帧主线程上传 GPU）。
final class DisplayLayerHostView: UIView {
    private var hosted: CALayer?

    func attach(_ layer: AVSampleBufferDisplayLayer) {
        guard !(hosted === layer) else { return }
        layer.removeFromSuperlayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        layer.automaticallyCompressesToLongSide = false
        layer.needsDisplayOnBoundsChange = false
        self.layer.addSublayer(layer)
        hosted = layer
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted?.frame = bounds
        CATransaction.commit()
    }
}

struct PreviewRepresentable: UIViewRepresentable {
    @EnvironmentObject private var cam: CameraManager

    func makeUIView(context: Context) -> DisplayLayerHostView {
        let v = DisplayLayerHostView()
        v.backgroundColor = .black
        v.attach(cam.displayLayer)
        return v
    }

    func updateUIView(_ uiView: DisplayLayerHostView, context: Context) {
        uiView.attach(cam.displayLayer)
    }
}
