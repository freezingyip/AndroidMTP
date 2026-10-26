# Development status

Project initialized on 26 October 2026. This chat has been moved into the AndroidMTP project.

## Version 0.1.0

Implemented: native sidebar and file table, storage selection, folder browsing, file/folder upload and download, new folders, rename, confirmed deletion of files and empty folders, progress/cancel, and drag-and-drop upload. Standard MTP is the default; no ADB command runs on launch.

Optional: ADB device authorization status and installation of individual APK files using an existing ADB installation. Wireless pairing and app management are future additions.

## Verification

- Release build and local app launch succeeded on this Apple Silicon Mac.
- MTP libraries are bundled and the ad-hoc bundle signature verifies.
- The installed Homebrew libraries target macOS 27.0, so this local app bundle also requires 27.0. A wider release needs libraries built for the intended minimum OS.
- Hardware-free checks passed for unsafe filenames, Unicode/case collisions, existing destinations, dangling symlinks, atomic download commit, cancellation state, progress above 4 GB, disconnected-service errors, ADB device parsing, and APK preflight.
- The C bridge passes compilation with `-Wall -Wextra -Werror`.
- This Command Line Tools installation does not include XCTest. The reusable standalone checks run with `./scripts/test.sh`; XCTest sources are retained for a full Xcode environment.

## Device test

The app detected the connected Vivo V11. The first session attempt was blocked: macOS reported that `ptpcamerad` (Apple's photo-import service) exclusively owns the MTP USB interface. A separate read-only libmtp diagnostic reproduced access denied. Storage browsing and transfers are not yet verified on the phone.

The app now shows connection failures directly inside its connection sheet and gives photo-importer conflict guidance. Permission to close Photos and restart its camera connection service has been requested. No phone files were changed during verification.

## Known limits

Cancelled or failed uploads can leave partial content on Android; the UI reports this. Downloads use private staging and do not replace an existing destination. Native MTP cancellation can wait for a transfer callback or USB timeout. There is no recursive delete, universal Trash, resume, or protected-app-data access in this version.
