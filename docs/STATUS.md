# Development status

## Version 0.2.0 — verified 26 October 2026

The previous direct USB backend competed with macOS's photo-import service. Version 0.2.0 prefers standard MTP commands through Apple's ImageCaptureCore service. It does not stop Photos, OneDrive, or the camera service, and does not enable USB debugging. The direct libmtp implementation remains a fallback for devices the system browser does not discover.

The actual app is connected to the X300 Pro and browsing internal storage. OneDrive and `ptpcamerad` remained running during the checks below. No permanent service or security settings were changed.

## Live verification

- System-managed discovery, session opening, storage listing, and folder browsing passed.
- Recursive upload, folder rename, and recursive download passed for four synthetic files, including a 5 MB binary, a Unicode filename, and a zero-byte file.
- All downloaded SHA-256 hashes matched the originals. Empty directories survived the round trip, and existing local destinations were rejected without replacement.
- A separate download through the actual app's file picker passed all three file hashes and empty-folder checks.
- Actual-app Disconnect → Connect succeeded, followed by folder refresh and browsing.
- The app still refreshed successfully after a second system-managed client completed and closed its session.

The durable summary is in `docs/verification-2026-10-26.json`. Detailed local evidence is under `.build/device-test/results/443CC348-D06D-4E4D-99A1-6E3F74180802/` and `.build/device-test/gui-downloads/20261026-c986b2/`. Synthetic `AndroidMTP-Test-...` folders remain on the phone. No pre-existing phone files were changed or deleted.

## Implementation and automated checks

The native sidebar/table supports storage selection, folder browsing, recursive transfers, create folder, rename, confirmed deletion of files/empty folders, cancellation, and drag-and-drop upload. ADB discovery and individual APK installation remain optional; wireless pairing/app management are future work.

The system backend streams bounded partial-object chunks using Android's advertised edit operations. It creates a one-byte placeholder before editing, avoiding ImageCaptureCore's empty outgoing-data request behavior. Empty files use the advertised truncate operation. Downloads use private staging and an atomic commit that cannot replace an existing destination.

`./scripts/test.sh` passes the standalone checks for file safety, codec framing and malformed data, Unicode, 64-bit values, transport selection/lifetimes, recursive byte round trips, chunk boundaries, cancellation/edit cleanup, collision preservation, compatibility preflight, and optional ADB handling. Tests use synthetic/fake transports and never access a phone. The C bridge also compiles with `-Wall -Wextra -Werror`.

The release build and ad-hoc signature verification passed. This local arm64 bundle requires macOS 27.0 because of its installed Homebrew fallback libraries; the source targets macOS 13+. The Command Line Tools installation lacks XCTest, so XCTest sources are retained for a full Xcode environment.

## Practical limits

- Physical multi-GB transfers have not been tested. The current phone advertises the required 64-bit partial-object operations; their values/framing are covered by automated checks.
- Devices without the Android edit extensions have a 64 MB system-upload compatibility limit and may not support empty-file creation through this path.
- Cancelled or failed uploads can leave partial content on Android; the UI reports this. Cancellation is checked between bounded requests, and a current native request may wait for its timeout.
- There is no recursive deletion, universal Trash, resume, or protected-app-data access.

The connection controls are inline rather than a SwiftUI sheet, avoiding the macOS 27 accessibility recursion observed with the earlier modal. Actual connection, download, reconnection, and folder inspection succeeded with the current interface.
