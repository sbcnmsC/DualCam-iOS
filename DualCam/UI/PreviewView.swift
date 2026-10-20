import SwiftUI
import UIKit

/// 预览画面直接用 CALayer 显示，不经过 SwiftUI 刷新，避免每帧重绘整个界面。
final class PreviewUIView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ image: CGImage) {
        layer.contents = image
    }
}

struct PreviewRepresentable: UIViewRepresentable {
    @EnvironmentObject private var cam: CameraManager

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        cam.previewView = view
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        cam.previewView = uiView
    }
}
