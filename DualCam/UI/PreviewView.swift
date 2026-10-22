import AVFoundation
import SwiftUI
import UIKit

/// 预览画面：把 CameraManager 的 AVSampleBufferDisplayLayer 放进 SwiftUI。
/// 合成帧由 GPU 渲染后直接送显示层（DisplayImmediately），不经过 SwiftUI 刷新，也不做 CPU 回读，
/// 所以延迟只有「相机出帧 → 一次 GPU 合成」。
final class PreviewUIView: UIView {
    private var hosted: CALayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        clipsToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(_ l: CALayer) {
        guard hosted !== l else { return }
        // 独立创建的图层 contentsScale 默认是 1，会按「点」而不是「像素」渲染，画面发软
        l.contentsScale = traitCollection.displayScale
        l.removeFromSuperlayer()
        layer.addSublayer(l)
        hosted = l
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

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.attach(cam.displayLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        uiView.attach(cam.displayLayer)
    }
}
