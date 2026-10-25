import MultipeerConnectivity
import SwiftUI

struct WirelessMonitorSheet: View {
    @StateObject private var service = MonitorDiscoveryService()
    @Environment(\.dismiss) private var dismiss

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

                Section {
                    Text("配对连接使用系统提供的加密会话。视频传输尚未启用；当前阶段先验证设备发现与用户确认流程。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("无线监看")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        service.stop()
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
            .onAppear { service.start() }
            .onDisappear { service.stop() }
        }
    }
}
