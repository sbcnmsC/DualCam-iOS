import SwiftUI
import UIKit

/// 截图风格的极简相机主界面：黑色控件区、满宽预览、固定焦段快捷键和大快门。
struct CameraHomeScreen: View {
    @EnvironmentObject private var cam: CameraManager
    @State private var showPanel = false
    @State private var panelTab: PanelTab = .pip

    private let zoomStops: [CGFloat] = [0.5, 1, 2, 5]

    var body: some View {
        GeometryReader { geo in
            let topHeight = max(geo.size.height * 0.145, 96)
            let previewHeight = min(geo.size.width * 4.0 / 3.0,
                                    max(geo.size.height - topHeight - 184, geo.size.width * 1.15))
            let previewSize = CGSize(width: geo.size.width, height: previewHeight)

            ZStack {
                Color.black

                VStack(spacing: 0) {
                    topControls
                        .frame(height: topHeight)

                    ZStack(alignment: .bottom) {
                        PreviewStage(size: previewSize)
                            .frame(width: previewSize.width, height: previewSize.height)

                        if showPanel {
                            ToolPanel(tab: $panelTab)
                                .frame(maxWidth: .infinity)
                                .frame(maxHeight: min(geo.size.height * 0.30, 240))
                                .background(Color.black.opacity(0.94))
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            zoomSelector
                                .padding(.bottom, 18)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: geo.size.width, height: previewHeight)
                    .clipped()

                    Spacer(minLength: 8)

                    shutterControls
                        .frame(height: 98)

                    modeControls
                        .frame(height: 58)

                    Spacer(minLength: 8)
                }

                OverlayLayer()
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black)
        .ignoresSafeArea()
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.22), value: showPanel)
    }

    private var topControls: some View {
        HStack(spacing: 30) {
            topIcon("bolt.fill", tint: cam.flashEnabled ? .yellow : .white) {
                cam.flashEnabled.toggle()
            }

            topIcon("timer", tint: cam.timerSeconds == 0 ? .white : .yellow) {
                cam.cycleTimer()
            }

            topIcon("moon.fill", tint: cam.cfg.lowLight ? .yellow : .white) {
                cam.cfg.lowLight.toggle()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 22)
        .foregroundStyle(.white)
    }

    private func topIcon(_ symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var zoomSelector: some View {
        let slot = cam.mainSlot
        let activeZoom = cam.displayZoom(slot: slot)

        return HStack(spacing: 8) {
            ForEach(zoomStops, id: \.self) { stop in
                let selected = abs(activeZoom - stop) < 0.18
                Button {
                    cam.selectZoomPreset(stop, slot: slot)
                } label: {
                    Text(zoomLabel(stop))
                        .font(.system(size: 14, weight: selected ? .bold : .medium))
                        .foregroundStyle(selected ? Color.yellow : Color.white)
                        .frame(width: 46, height: 46)
                        .background {
                            Circle().fill(selected ? Color.white.opacity(0.15) : Color.clear)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("焦段 \(zoomLabel(stop))")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }

    private func zoomLabel(_ value: CGFloat) -> String {
        if value == 0.5 { return ".5" }
        if value == 1 { return "1×" }
        return String(Int(value))
    }

    private var shutterControls: some View {
        HStack {
            Button {
                cam.cfg.showGrid.toggle()
            } label: {
                Image(systemName: "square.grid.3x3")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(cam.cfg.showGrid ? Color.yellow : Color.white)
                    .frame(width: 54, height: 54)
                    .overlay(Circle().stroke(cam.cfg.showGrid ? Color.yellow : Color.white.opacity(0.35), lineWidth: 2))
                    .background(Circle().fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button {
                cam.shutterTapped()
            } label: {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.23), lineWidth: 5)
                        .frame(width: 82, height: 82)
                    if cam.captureMode == .photo {
                        Circle().fill(Color.white).frame(width: 68, height: 68)
                    } else {
                        RoundedRectangle(cornerRadius: cam.isRecording ? 8 : 34)
                            .fill(Color.red)
                            .frame(width: cam.isRecording ? 30 : 68, height: cam.isRecording ? 30 : 68)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: cam.isRecording)
            }
            .buttonStyle(.plain)
            .disabled(!cam.ready)
            .opacity(cam.ready ? 1 : 0.42)
            .accessibilityLabel(cam.captureMode == .photo ? "拍照" : (cam.isRecording ? "停止录像" : "开始录像"))

            Spacer(minLength: 0)

            Button {
                showPanel.toggle()
            } label: {
                Image(systemName: "circle.grid.3x3.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(showPanel ? Color.yellow : Color.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Color.white.opacity(0.11)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("相机设置")
        }
        .padding(.horizontal, 35)
    }

    private var modeControls: some View {
        HStack(spacing: 18) {
            Spacer(minLength: 4)

            HStack(spacing: 0) {
                modeButton(.video)
                modeButton(.photo)
            }
            .padding(4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .overlay(Capsule().stroke(Color.white.opacity(0.04), lineWidth: 1))

            Spacer(minLength: 4)

            Button {
                cam.swapCameras()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(Color.white)
                    .frame(width: 54, height: 54)
                    .background(Circle().fill(Color.white.opacity(0.11)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("交换主副画面")
        }
        .padding(.leading, 22)
        .padding(.trailing, 25)
    }

    private func modeButton(_ mode: CaptureMode) -> some View {
        Button {
            guard !cam.isRecording else { return }
            cam.captureMode = mode
        } label: {
            Text(mode == .video ? "视频" : "照片")
                .font(.system(size: 16, weight: cam.captureMode == mode ? .semibold : .regular))
                .foregroundStyle(cam.captureMode == mode ? Color.yellow : Color.white.opacity(0.88))
                .frame(width: 78, height: 44)
                .background {
                    if cam.captureMode == mode {
                        Capsule().fill(LinearGradient(
                            colors: [Color.white.opacity(0.17), Color.white.opacity(0.08)],
                            startPoint: .top, endPoint: .bottom
                        ))
                    }
                }
        }
        .buttonStyle(.plain)
    }
}
