# DualCam Studio integration audit for DualCam-iOS

Date: 2026-10-21

## Goal

Improve `sbcnmsC/DualCam-iOS` while preserving the existing app and its history. This audit is intentionally isolated on `integration/dualcam-studio-audit`; it does not replace files on `main` or import third-party source blindly.

Reference project: https://github.com/mrsathyasankar/dualcam-studio  
Reference license: MIT (retain its copyright and license notice if any substantial code is copied).

## Current repository findings

The current project already has a native iOS target, SwiftUI screens, an `AVCaptureMultiCamSession`-based `CameraManager`, a `Compositor`, a `VideoRecorder`, a preview layer, filters, settings, and Live Photo work. The project targets iOS 17 and uses Swift language mode 5. Its existing README explicitly says that full real-device validation has not yet been completed.

This is significant overlap with DualCam Studio. Replacing the current camera engine wholesale would risk regressing existing features (filtering, per-lens controls, Live Photo, timer, and current layout gestures) and would introduce a broad Swift 6 / architecture migration at the same time.

## Recommended integration approach

### Phase 1 — keep the existing capture engine

Keep `CameraManager`, `Compositor`, and `VideoRecorder` as the production path initially. Compare the reference architecture and port only isolated improvements after a focused code review.

### Phase 2 — highest-value candidates

1. **Single layout source of truth.** Compare the current normalized PiP/split geometry and crop calculations with DualCam Studio's `LayoutSolver`. Extract or adapt only the pure geometry math if a demonstrable preview-versus-recording mismatch is found.
2. **Capability negotiation.** Audit camera-pair selection, format selection, `AVCaptureMultiCamSession.hardwareCost`, and `systemPressureCost`. Keep the current downgrade behavior if it is already correct; otherwise add a deterministic quality/FPS fallback ladder.
3. **Recording resilience.** Compare handling for storage preflight, writer back-pressure, interruption/background transitions, thermal pressure, and low battery. Port safeguards individually rather than replacing the writer.
4. **Test coverage.** Add unit tests for geometry, crop/aspect-fill, format fallback decisions, and recording state transitions. Keep hardware capture tests on a real device; simulator tests must use a mock capture engine.
5. **Real-device validation.** On iPhone 16-series hardware, test supported front/rear lens pairs, portrait and landscape, photo/video, audio sync, layout changes while recording, interruption recovery, and sustained thermal behavior.

## Compatibility notes

- Do not copy DualCam Studio's entire `Sources/` tree into this project: its types and module boundaries do not match the existing `DualCam` target.
- Do not change the app's bundle identifier, signing settings, or existing release workflow as part of this audit.
- Keep all source imports attributable; if code is copied or adapted from the MIT project, include the MIT copyright and license notice.
- A simulator build cannot validate actual MultiCam hardware behavior. The iPhone 16 model (base / Plus / Pro / Pro Max) and iOS version should be recorded for test results.

## Acceptance checklist for the implementation PR

- [ ] No changes to `main` until review/merge.
- [ ] Diff contains only scoped changes and any required license notice.
- [ ] Project compiles with the repository's current Xcode project configuration.
- [ ] Unit tests cover any extracted pure logic.
- [ ] Real-device smoke test recorded separately from simulator CI.
- [ ] No claim of IPA signing or device verification unless actually performed.

## Decision

Proceed with small, independently testable improvements. Do not wholesale-replace the existing camera stack. The immediate next implementation should be a focused audit of format negotiation and layout parity, then a separate PR for the specific fixes supported by code and tests.
