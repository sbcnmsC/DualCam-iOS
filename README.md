# DualCam iOS

Native iPhone camera app scaffold using Swift and SwiftUI, based on the supplied DualCam requirements.

## Current implementation

- Attempts to start an `AVCaptureMultiCamSession` with the rear and front wide cameras on supported devices.
- Basic live composite preview with picture-in-picture / split layout switch.
- Basic grid overlay, zoom buttons, timer UI, and JPEG photo saving to Photos.
- Xcode project targeting iOS 17+.

## Known limitations

This is an initial scaffold, not a complete implementation of every requirement. In particular:

- Video recording and export are not implemented yet; the record control currently displays a status message.
- Picture-in-picture drag/resize/swap and split-divider gestures are not implemented.
- Flash, timer capture delay, exposure slider, filter collection, full camera-combination switching, manual ISO/shutter, white balance, focus controls, and true 4K / 60 fps selection are incomplete or UI-only.
- Live Photo, saving original streams, audio recording, stabilization controls, interruption recovery, and extensive device capability negotiation are not implemented.
- Multi-camera support varies by iPhone model and camera combination. This code requires device-side validation and may need adjustments for specific hardware.

## Build and test

1. On macOS, open `DualCam.xcodeproj` in Xcode 16 or newer.
2. Select your own development Team and change `com.example.DualCam` to a unique Bundle Identifier if needed.
3. Connect a physical iPhone running iOS 17 or later that supports `AVCaptureMultiCamSession`.
4. Grant camera and Photos permissions and check the Xcode console for capture-session errors.

The project has **not** been compiled with Xcode or tested on a physical iPhone in this environment. No successful build or device test is claimed.