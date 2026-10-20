import SwiftUI

struct CameraScreen: View {
    @EnvironmentObject private var camera: CameraManager
    @State private var showSettings = false
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                if let image = camera.previewImage {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height).clipped().ignoresSafeArea()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.aperture").font(.system(size: 48))
                        Text(camera.statusText).multilineTextAlignment(.center)
                    }.foregroundStyle(.white.opacity(0.8)).padding(28)
                }
                if camera.showGrid { GridOverlay().stroke(.white.opacity(0.35), lineWidth: 0.6).ignoresSafeArea() }
                VStack {
                    HStack {
                        Button { camera.flashEnabled.toggle() } label: { Image(systemName: camera.flashEnabled ? "bolt.fill" : "bolt.slash") }
                        Button { camera.cycleTimer() } label: { Image(systemName: "timer"); Text(camera.timerSeconds == 0 ? "关" : "\(camera.timerSeconds)s") }
                        Spacer()
                        Text(camera.statusText).font(.caption).lineLimit(1)
                        Spacer()
                        Button { camera.toggleLayout() } label: { Image(systemName: "rectangle.split.2x1") }
                        Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    }.buttonStyle(.plain).padding(14).background(.black.opacity(0.45), in: Capsule())
                    Spacer()
                    HStack(spacing: 26) {
                        Button { camera.setZoom(1) } label: { Text("1×") }
                        Button { camera.setZoom(2) } label: { Text("2×") }
                        Spacer()
                        Button { camera.capturePhoto() } label: {
                            Circle().fill(.white).frame(width: 68, height: 68).overlay(Circle().stroke(.gray, lineWidth: 4).padding(5))
                        }
                        Spacer()
                        Button { camera.toggleRecording() } label: {
                            Image(systemName: "record.circle").font(.system(size: 38)).foregroundStyle(.red)
                        }
                    }.font(.system(size: 15, weight: .semibold)).padding(18).foregroundStyle(.white)
                }.padding(.top, 12).padding(.bottom, 16)
            }
            .sheet(isPresented: $showSettings) {
                Form {
                    Toggle("三分构图线", isOn: $camera.showGrid)
                    Toggle("前置镜像", isOn: .constant(true))
                    Picker("画面布局", selection: Binding(get: { camera.layout == .pictureInPicture ? "PIP" : "分屏" }, set: { camera.layout = $0 == "PIP" ? .pictureInPicture : .split })) {
                        Text("画中画").tag("PIP")
                        Text("上下分屏").tag("分屏")
                    }
                    Text("分辨率、帧率、手动曝光和视频录制尚未完整接入。")
                }.presentationDetents([.medium, .large])
            }
        }.statusBarHidden()
    }
}

private struct GridOverlay: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = rect.width * CGFloat(i) / 3
            let y = rect.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: rect.height))
            p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return p
    }
}