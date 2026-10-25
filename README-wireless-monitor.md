# DualCam Wireless Live Monitor (Network.framework + WebRTC)

This implementation branch is based on `optimize/high-res-preview-app-icon` and does not modify `main`.

## Transport choice

- **Live video:** WebRTC, sending only the composited preview buffer from DualCam. The buffer already contains both-camera composition, PiP/split layout, aspect/crop and filters. The receiver renders the remote video track and does not run a second compositor.
- **Discovery and pairing:** Network.framework Bonjour discovery and TCP connections with `includePeerToPeer = true`. The first pairing uses ephemeral Curve25519 ECDH; both devices display a short safety code that the user must compare and confirm. After confirmation, WebRTC SDP/ICE signalling is AES-GCM encrypted with directional keys derived through HKDF.
- **Media security:** WebRTC uses DTLS-SRTP. No STUN/TURN server is configured, so the WebRTC media path attempts directly reachable host candidates and does not silently relay video through a cloud service.
- **AirDrop:** Keep it for transferring already-recorded photo/video files. It is not used as a live preview transport.
- **Bluetooth:** It may be available to the Network.framework discovery/control path through peer-to-peer networking, but it is not treated as the HD video media channel. For reliable live video, use the same Wi-Fi network. The current WebRTC path does not claim Bluetooth-only live video.

## Pairing and usage

1. Install the same signed build on both iOS devices and put them on the same Wi-Fi network.
2. Open DualCam and tap the wireless monitor icon in the top bar on both devices; allow Local Network access.
3. One device taps **Connect** next to the other.
4. Both devices show a six-digit code. Compare the codes out-of-band on both screens. If they differ, reject the connection. Only tap confirmation after the codes match.
5. On the receiving device tap **Receive View**; on the camera device tap **Send Composite View**.
6. Tap **Stop Video** to stop the stream, or **Disconnect secure pairing** to end the pairing session.

## Performance strategy

- Reuse the existing preview CVPixelBuffer; do not call `snapshot`, `createCGImage`, or another CPU readback.
- The video source uses a one-frame mailbox on a separate queue. If encoding falls behind, the most recent frame replaces the pending frame instead of building an unbounded queue.
- Start at 30 fps and the current preview buffer size (long edge capped at 1920 px). Measure end-to-end latency and thermal behaviour on devices before raising resolution/fps.
- The receiver suspends its own local camera session while displaying the stream to save capture and thermal resources.

## Security considerations

The safety code is a short authentication string derived from the ephemeral ECDH shared secret, with initiator/responder nonces and HKDF-derived directional keys. Both users must compare the displayed codes; this detects a man-in-the-middle on the signalling connection when users follow the confirmation flow. After that, signalling payloads use AES-GCM and video media is protected by WebRTC DTLS-SRTP. Do not auto-accept pairing or skip safety-code comparison.

## Apple documentation

- Network framework: https://developer.apple.com/documentation/network
- NWParameters peer-to-peer transport option: https://developer.apple.com/documentation/network/nwparameters/includepeertopeer
- Bonjour service discovery: https://developer.apple.com/documentation/network/nwbrowser/descriptor-swift.enum
- VideoToolbox hardware encoding/decoding (future native-media alternative): https://developer.apple.com/documentation/videotoolbox
- AirDrop/system sharing UI: https://developer.apple.com/documentation/uikit/uiactivityviewcontroller
- Multipeer Connectivity is useful historical reference, but Apple currently marks MCSession APIs deprecated and directs new implementations to Network.framework.

## Validation status

GitHub Actions builds an unsigned IPA; this only validates source compilation and packaging. Two-device pairing, code comparison, video rendering, actual latency, reconnection, frame drops, thermal performance and install/signing must still be tested on physical devices. The target of under 150 ms is an optimisation goal, not a measured claim.
