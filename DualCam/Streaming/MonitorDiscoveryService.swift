import Combine
import Foundation
import MultipeerConnectivity
import UIKit

/// Local discovery and encrypted peer pairing. Media transport is deliberately separate:
/// this session is for discovery/signalling only, not for pushing every video frame.
final class MonitorDiscoveryService: NSObject, ObservableObject {
    static let serviceType = "dualcam-monitor"

    @Published private(set) var discoveredPeers: [MCPeerID] = []
    @Published private(set) var connectedPeers: [MCPeerID] = []
    @Published private(set) var incomingPeerName: String?
    @Published private(set) var statusText = "尚未连接"
    var onSignalReceived: ((Data) -> Void)?

    private let localPeer = MCPeerID(displayName: MonitorDiscoveryService.makeDisplayName())
    private var session: MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var pendingInvitation: ((Bool, MCSession?) -> Void)?

    override init() {
        super.init()
        session = MCSession(peer: localPeer, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
    }

    func start() {
        guard advertiser == nil, browser == nil else { return }
        let info = ["app": "DualCam", "protocol": "1"]
        let newAdvertiser = MCNearbyServiceAdvertiser(peer: localPeer, discoveryInfo: info, serviceType: Self.serviceType)
        let newBrowser = MCNearbyServiceBrowser(peer: localPeer, serviceType: Self.serviceType)
        newAdvertiser.delegate = self
        newBrowser.delegate = self
        advertiser = newAdvertiser
        browser = newBrowser
        newAdvertiser.startAdvertisingPeer()
        newBrowser.startBrowsingForPeers()
        statusText = "正在搜索附近的 DualCam 设备…"
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        pendingInvitation?(false, nil)
        pendingInvitation = nil
        incomingPeerName = nil
        session.disconnect()
        discoveredPeers = []
        connectedPeers = []
        statusText = "已断开"
    }

    func connect(to peer: MCPeerID) {
        guard !session.connectedPeers.contains(peer) else { return }
        browser?.invitePeer(peer, to: session, withContext: Data("DualCam pairing v1".utf8), timeout: 20)
        statusText = "正在请求连接：\(peer.displayName)"
    }

    func acceptIncomingInvitation() {
        pendingInvitation?(true, session)
        pendingInvitation = nil
        incomingPeerName = nil
        statusText = "已接受连接请求"
    }

    func declineIncomingInvitation() {
        pendingInvitation?(false, nil)
        pendingInvitation = nil
        incomingPeerName = nil
        statusText = "已拒绝连接请求"
    }

    func sendSignal(_ data: Data, reliably: Bool = true) throws {
        guard !session.connectedPeers.isEmpty else { throw MonitorError.notConnected }
        try session.send(data, toPeers: session.connectedPeers, with: reliably ? .reliable : .unreliable)
    }

    private static func makeDisplayName() -> String {
        let name = UIDevice.current.name
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        return String(name.prefix(40)).isEmpty ? "DualCam-device" : String(name.prefix(40))
    }

    enum MonitorError: LocalizedError {
        case notConnected
        var errorDescription: String? {
            switch self {
            case .notConnected: return "尚未连接接收设备"
            }
        }
    }
}

extension MonitorDiscoveryService: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        DispatchQueue.main.async {
            guard self.pendingInvitation == nil else {
                invitationHandler(false, nil)
                return
            }
            self.pendingInvitation = invitationHandler
            self.incomingPeerName = peerID.displayName
            self.statusText = "等待确认：\(peerID.displayName)"
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.statusText = "设备广播失败：\(error.localizedDescription)" }
    }
}

extension MonitorDiscoveryService: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        guard info?["app"] == "DualCam", info?["protocol"] == "1" else { return }
        DispatchQueue.main.async {
            guard !self.discoveredPeers.contains(peerID),
                  peerID != self.localPeer else { return }
            self.discoveredPeers.append(peerID)
            self.statusText = "发现 \(self.discoveredPeers.count) 台设备"
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.discoveredPeers.removeAll { $0 == peerID }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.statusText = "搜索设备失败：\(error.localizedDescription)" }
    }
}

extension MonitorDiscoveryService: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectedPeers = session.connectedPeers
            switch state {
            case .connected: self.statusText = "已安全连接：\(peerID.displayName)"
            case .connecting: self.statusText = "正在连接：\(peerID.displayName)"
            case .notConnected: self.statusText = "连接已断开"
            @unknown default: self.statusText = "连接状态未知"
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // Signalling messages are small JSON payloads; video frames never traverse this session.
        DispatchQueue.main.async { self.onSignalReceived?(data) }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
