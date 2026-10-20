# DualCam Studio integration audit for DualCam-iOS

Date: 2026-10-21

## Goal

Improve `sbcnmsC/DualCam-iOS` while preserving the existing app and its history. This audit is intentionally isolated on `integration/dualcam-studio-audit`; it does not replace files on `main` or import third-party source blindly.

Reference project: https://github.com/mrsathyasankar/dualcam-studio  
Reference license: MIT (retain its copyright and license notice if any substantial code is copied).

## Current repository findings

The current project already has a native iOS target, SwiftUI screens, an `AVCaptureMultiCamSession`-based `CameraManager`, a `Compositor`, a `VideoRecorder`, audio capture and optional audio writing, a preview layer, filters, settings, and an experimental Live Photo writer. The project targets iOS 17 and uses Swift language mode 5. Its existing README explicitly says that full real-device validation has not yet been completed.

This is significant overlap with DualCam Studio. Replacing the current camera engine wholesale would risk regressing existing features (filtering, per-lens controls, Live Photo, timer, and current layout gestures) and would introduce a broad Swift 6 / architecture migration at the same time.

## Live Photo status and integration strategy

The existing DualCam-iOS branch already contains an experimental Live Photo pipeline in `LivePhotoWriter.swift` and `CameraManager.swift`: it builds a matching JPEG/MOV pair, embeds a shared content identifier and still-image-time metadata, buffers pre/post frames, and saves the pair as one Photos asset. The README correctly marks this as not yet fully verified on a real device. DualCam Studio's documented feature set is primarily video recording and does not replace this Live Photo pipeline, so the integration must preserve it and harden it rather than remove it.

### Live Photo hardening checklist

1. **Implemented in this branch:** validate that the still-frame index is within the buffered sequence and reject mixed-size or undecodable frame JPEGs before creating a movie. This prevents silently clamping a bad keyframe index or stretching malformed frames.
2. Verify the paired JPEG/MOV is recognized by Photos as a Live Photo on iPhone 16-series hardware, including playback and the key photo frame.
3. Verify the MakerApple identifier and MOV content identifier match, and that the still-image-time metadata track lands on the intended frame.
4. Test pre/post capture timing, insufficient buffered frames, rapid repeat captures, disabling Live Photo while a capture is pending, and writer failures.
5. Keep the composited still and motion frames visually consistent with the active layout, filter, crop, orientation, and front-camera mirror state.
6. Test Photos permission denial, low storage, app backgrounding/interruption, and cleanup of temporary MOV files.
7. **Audio note:** normal video recording already has an audio output/writer path. The experimental Live Photo movie writer currently writes video plus still-image-time metadata only; audio capture/writing must be deliberately added and validated if the product requirement is sound-bearing Live Photos. Do not claim audio support until verified.

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

## Native camera UI decision

Use a native SwiftUI interface styled to feel familiar to iPhone users (clean black camera canvas, native-feeling shutter/control affordances, compact top controls, bottom mode selector and responsive safe-area behavior). A third-party app cannot embed or reuse Apple's private Camera app interface itself; use public SwiftUI/UIKit APIs and AVFoundation while keeping the app's dual-camera controls accessible.

## Decision

Proceed with small, independently testable improvements. Do not wholesale-replace the existing camera stack. The first PR adds a safe resource-budget failure path; the next implementation should improve the resolution/FPS negotiation ladder, compare layout parity, and harden the existing experimental Live Photo pipeline. Each change should remain separately reviewable. Do not claim Live Photo support is production-ready until the paired asset is verified in Photos on a real iPhone.
