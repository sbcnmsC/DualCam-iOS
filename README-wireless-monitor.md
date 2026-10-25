# DualCam Wireless Live Monitor

This isolated branch is based on `feature/iphone16-camera-control`; it does not modify `main`.

## Implemented in this branch

- A `CompositedFrameSource` taps the already-rendered preview pixel buffer, avoiding screenshots and CPU image readback.
- `LiveMonitorRTCService` sends that composed frame via WebRTC and receives SDP/ICE signalling through the paired MultipeerConnectivity session.
- MultipeerConnectivity discovers nearby devices, requires user acceptance, and encrypts pairing/signalling traffic.
- The monitor sheet offers **Send Composite View** and **Receive View**, shows connection status, supports stopping the stream, and renders remote video.
- The receiving device suspends its own camera session while monitoring to reduce resource use.
- WebRTC is pinned to the M155-compatible release line through Swift Package Manager. ICE servers are intentionally empty: this branch attempts LAN host-candidate connectivity only and does not use cloud STUN/TURN relays.
- Bonjour/local network privacy declarations are included. XcodeGen and GitHub Actions produce an unsigned IPA artifact.

## What is included in the transmitted view

The sender shares the final composed preview after dual-camera layout and filters, so PiP/split layout, PiP placement, output aspect ratio, and filter appearance travel as one video stream. It does not send two independent raw camera feeds and does not transmit microphone audio.

## How to try it

1. Install the same build on both iOS devices and connect both to the same Wi-Fi network.
2. Open **Wireless Monitor** on both devices and allow local-network access.
3. On one device, tap **Connect** next to the other device; accept the invitation on the other device.
4. On the receiving device, tap **Receive View**. On the camera device, tap **Send Composite View**.
5. Tap **Stop Video** to end the stream. If local Wi-Fi direct connectivity fails, check that the access point does not isolate clients.

## Validation status

GitHub Actions can verify that the source compiles and an unsigned IPA is packaged. This does not replace testing on two physical devices. End-to-end latency, sustained thermal behaviour, reconnects, Wi-Fi client isolation, and signing/install behaviour still need real-device validation. A target below 150 ms is an optimisation goal, not a measured result.
