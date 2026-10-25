# DualCam Wireless Live Monitor — implementation status

This branch is an isolated implementation track based on `feature/iphone16-camera-control`. It does not modify `main`.

## Current phase

- Adds a fan-out interface for the already-composited preview pixel buffer (`CompositedFrameSource`).
- Publishes the same bounded-resolution preview buffer used by the local display; no screenshot or CPU readback is added.
- Adds encrypted MultipeerConnectivity peer discovery, user-confirmed invitations, and a basic pairing sheet.
- Adds the iOS local-network permission explanation and Bonjour service declarations.
- Adds a branch-specific unsigned IPA build workflow.

## Important limitation

**Real-time video transport is not implemented in this phase yet.** Pairing and the frame-source seam are groundwork only; the UI explicitly tells users that video transport is not yet enabled. The next phase should add a pinned WebRTC dependency, feed composited pixel buffers into a WebRTC video source, exchange SDP/ICE through the paired local session, and render the remote track on the receiving iPhone/iPad.

## Acceptance checks for the next phase

1. Build on Xcode 16 / iOS SDK 18+ without regressing Camera Control.
2. Discover and pair two real iOS devices on the same Wi-Fi.
3. Send only the composited preview (PiP/split/filter/aspect), not both raw camera feeds.
4. Measure end-to-end latency and verify reconnect, stop, and resource cleanup on-device.
5. Keep the pull request draft until the real-device tests pass.
