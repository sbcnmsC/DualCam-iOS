import SwiftUI
import AVFoundation
import UIKit

/// Hosts AVSampleBufferDisplayLayer directly so preview frames stay on the sample-buffer path.
final class DisplayLayerHostView: UIView {
    private var hostedLayer: AVSampleBufferDisplayLayer?

    func attach(_ displayLayer: AVSampleBufferDisplayLayer) {
        guard hostedLayer !== displayLayer else { return }
        hostedLayer?.removeFromSuperlayer()
        displayLayer.removeFromSuperlayer()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        layer.addSublayer(displayLayer)
        hostedLayer = displayLayer
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostedLayer?.frame = bounds
        CATransaction.commit()
    }
}

struct PreviewRepresentable: UIViewRepresentable {
    @EnvironmentObject private var cam: CameraManager

    func makeUIView(context: Context) -> DisplayLayerHostView {
        let view = DisplayLayerHostView()
        view.backgroundColor = .black
        view.layer.masksToBounds = true
        view.attach(cam.displayLayer)
        return view
    }

    func updateUIView(_ uiView: DisplayLayerHostView, context: Context) {
        uiView.attach(cam.displayLayer)
    }
}
