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

The app connected to the Vivo V11 and browsed its internal storage using standard USB MTP. Apple’s photo-import service (`ptpcamerad`) initially owned the interface; the user authorized closing Photos, restarting the camera service, and temporarily closing/reopening OneDrive for testing. OneDrive was reopened and its process verified after testing; the camera service was also verified running normally. No permanent service or security settings were changed. An attempted temporary service unload was refused by macOS System Integrity Protection.

The live test found and fixed a root-folder creation bug: libmtp's folder-creation and file-upload APIs use different root-parent conventions. Regression checks now cover both.

A hardware round-trip using the app's MTP service passed: recursive upload, folder rename, recursive download, SHA-256 comparisons for three files (45,126 bytes), a Unicode filename, an empty directory, and rejection of an existing local destination. Test evidence is saved locally at `.build/device-test/results/9881E43A-4D85-43EA-8326-8C0067CADDED/result.json`.

The synthetic test folder remains on Android as `AndroidMTP-Test-20261026-7ffab5-verified`. No pre-existing phone files were changed or deleted.

## Interface verification

macOS 27 accessibility inspection exposed a framework recursion crash during dismissal of the SwiftUI connection sheet. The connection controls now appear inline in the main window, with stable accessibility labels and preserved file-row accessibility. The updated window and inline controls were inspected successfully. The phone was no longer detected in MTP mode during the final check, so a full graphical reconnect after this final UI change remains to be rechecked. The live transfer-engine test above passed independently of the graphical interface.

## Known limits

Cancelled or failed uploads can leave partial content on Android; the UI reports this. Downloads use private staging and do not replace an existing destination. Native MTP cancellation can wait for a transfer callback or USB timeout. There is no recursive delete, universal Trash, resume, or protected-app-data access in this version.
