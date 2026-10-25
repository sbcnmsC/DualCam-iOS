import MultipeerConnectivity
import SwiftUI
import WebRTC

struct WirelessMonitorSheet: View {
    @StateObject private var service = MonitorDiscoveryService()
    @StateObject private var rtc = LiveMonitorRTCService()
    @EnvironmentObject private var cam: CameraManager
    @Environment(\.dismiss) private var dismiss
    @State private var mode: MonitorMode = .idle

    private var incomingPresented: Binding<Bool> {
        Binding(
            get: { service.incomingPeerName != nil },
            set: { if !$0 { service.declineIncomingInvitation() } }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("连接状态") {
                    Label(service.statusText, systemImage: service.connectedPeers.isEmpty ? "wifi" : "checkmark.shield.fill")
                    if !service.connectedPeers.isEmpty {
                        ForEach(service.connectedPeers, id: \.displayName) { peer in
                            Label(peer.displayName, systemImage: "iphone.gen3")
                        }
                    }
                    Label(rtc.statusText, systemImage: mode == .idle ? "video.slash" : "video")
                        .foregroundStyle(.secondary)
                }

                Section("附近的设备") {
                    if service.discoveredPeers.isEmpty {
                        ContentUnavailableView("正在搜索设备", systemImage: "dot.radiowaves.left.and.right",
                                               description: Text("请让两台设备打开 DualCam，并允许访问本地网络。"))
                    } else {
                        ForEach(service.discoveredPeers, id: \.displayName) { peer in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peer.displayName).font(.body)
                                    Text("DualCam · 局域网").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("连接") { service.connect(to: peer) }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(service.connectedPeers.contains(peer))
                            }
                        }
                    }
                }

                Section("实时画面") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("相机端发送合成画面，监看端接收同一幅画面。请先在两台设备间完成配对。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Button {
                                startSending()
                            } label: {
                                Label("发送合成画面", systemImage: "dot.radiowaves.left.and.right")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(service.connectedPeers.isEmpty || mode != .idle)

                            Button {
                                startReceiving()
                            } label: {
                                Label("接收画面", systemImage: "play.rectangle")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(service.connectedPeers.isEmpty || mode != .idle)
                        }

                        if mode == .receiving {
                            ZStack {
                                Color.black
                                if rtc.remoteVideoTrack == nil {
                                    VStack(spacing: 8) {
                                        ProgressView().tint(.white)
                                        Text("等待相机端发送画面…")
                                            .font(.callout)
                                            .foregroundStyle(.white.opacity(0.8))
                                    }
                                } else {
                                    RemoteMonitorVideoSurface(track: rtc.remoteVideoTrack)
                                }
                            }
                            .aspectRatio(9.0 / 16.0, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
                        }

                        if mode != .idle {
                            Button(role: .destructive) {
                                stopVideo()
                            } label: {
                                Label("停止视频", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("传输说明") {
                    Text("视频帧由 WebRTC 通过局域网直连传输；配对与信令使用系统加密会话。当前不配置 STUN/TURN 云中继，若路由器开启设备隔离，直连可能失败。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("无线监看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        cleanup()
                        dismiss()
                    }
                }
            }
            .alert("设备连接请求", isPresented: incomingPresented) {
                Button("拒绝", role: .cancel) { service.declineIncomingInvitation() }
                Button("允许连接") { service.acceptIncomingInvitation() }
            } message: {
                Text("\(service.incomingPeerName ?? "另一台设备") 请求与此设备建立加密连接。")
            }
            .onAppear { configureAndStart() }
            .onDisappear { cleanup() }
        }
    }

    private func configureAndStart() {
        let discovery = service
        let transport = rtc
        discovery.onSignalReceived = { [weak transport] data in
            transport?.handleSignal(data)
        }
        let frameSource = cam.compositedFrameSource
        let modeBinding = $mode
        transport.onPeerStopped = {
            // A remote stop should return the local UI to idle and detach its frame sink.
            frameSource.setSink(nil)
            cam.setLocalCameraCaptureSuspended(false)
            DispatchQueue.main.async { modeBinding.wrappedValue = .idle }
        }
        transport.onSignal = { [weak discovery, weak transport] data in
            do {
                try discovery?.sendSignal(data)
            } catch {
                DispatchQueue.main.async {
                    // Exposed through the transport's status text for a visible, actionable failure.
                    transport?.reportSignallingFailure(error.localizedDescription)
                }
            }
        }
        service.start()
    }

    private func startSending() {
        guard !service.connectedPeers.isEmpty else { return }
        mode = .sending
        let transport = rtc
        cam.compositedFrameSource.setSink { [weak transport] frame in
            transport?.push(frame)
        }
        rtc.startSending()
    }

    private func startReceiving() {
        guard !service.connectedPeers.isEmpty else { return }
        mode = .receiving
        cam.setLocalCameraCaptureSuspended(true)
        rtc.startReceiving()
    }

    private func stopVideo() {
        cam.compositedFrameSource.setSink(nil)
        cam.setLocalCameraCaptureSuspended(false)
        rtc.stopAndNotifyPeer()
        mode = .idle
    }

    private func cleanup() {
        cam.compositedFrameSource.setSink(nil)
        cam.setLocalCameraCaptureSuspended(false)
        rtc.onSignal = nil
        rtc.onPeerStopped = nil
        service.onSignalReceived = nil
        rtc.stop()
        service.stop()
        mode = .idle
    }
}

private enum MonitorMode {
    case idle
    case sending
    case receiving
}

private struct RemoteMonitorVideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        view.backgroundColor = .black
        context.coordinator.update(track: track, renderer: view)
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        context.coordinator.update(track: track, renderer: uiView)
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.update(track: nil, renderer: uiView)
    }

    final class Coordinator {
        private weak var currentTrack: RTCVideoTrack?

        func update(track: RTCVideoTrack?, renderer: RTCMTLVideoView) {
            if currentTrack === track { return }
            currentTrack?.remove(renderer)
            currentTrack = track
            track?.add(renderer)
        }
    }
}
