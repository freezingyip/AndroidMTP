# Development status

## Version 0.5.0 — easier installation, 26 October 2026

Added a drag-to-Applications DMG with a local installation guide and a direct download link at the top of the README. The original libusb/libmtp release sources are rebuilt for macOS 13 instead of shipping the macOS 27 Homebrew binaries. The libusb build explicitly uses its existing pipe/fcntl fallback rather than the pipe2 API introduced in the newer SDK. Release packaging supports the isolated portable bundle, includes required dependency notices, and verifies the DMG.

The mounted DMG, Applications shortcut, local guide, app copy, code signatures, macOS 13 deployment targets, and absence of external development-library paths passed verification. The regression suite also passed against the rebuilt libraries.

The release still uses ad hoc signing: no Developer ID identity is present, and the user confirmed they do not have Apple Developer Program membership. First opening may therefore require the app-specific approval documented by Apple; no security setting is changed automatically. macOS 13 is the deployment target, not a claim that the app has been tested on every older macOS version.

## Version 0.4.1 — app icon, 26 October 2026

Added original AI-generated mint-and-teal phone/folder icon artwork, a complete ICNS bundle of 16–1024 pixel representations, and its reproducible sizing script. Packaging copies the icon into app resources and sets CFBundleIconFile; launch also applies the icon explicitly so the running Dock icon refreshes. Artwork and prompt are committed under `assets/`. The 32-pixel representation was visually checked, the ICNS structure validated, and the release bundle built and signed successfully.

## Version 0.4.0 — Finder copy/paste, 26 October 2026

Added file-list Copy (⌘C) and Paste (⌘V), Edit menu commands, and context-menu actions. Copy downloads selected files/folders into a unique temporary directory and publishes standard file URLs only after all transfers succeed. Paste reads Finder file URLs and uploads to the current Android folder. Text fields retain native text commands through the responder chain. Transfers keep existing progress, cancellation, and collision checks.

The actual app passed a Finder → Android → Finder round trip using ⌘C/⌘V in both apps. The 55-byte synthetic file matched its original SHA-256 after Finder paste. A uniquely named test file remains on the phone; no existing phone files were changed. Evidence: `docs/clipboard-verification-2026-10-26.json`. Select All (⌘A) is available for the file list and native text fields. Actual-app text Select All → Copy → clear → Paste restored the search text without triggering an upload.

Tests use a private named macOS pasteboard and a fake phone transport. They verify multiple files/folders, Unicode filenames, downloaded bytes, upload URL routing, rejection of plain text, preserved clipboard on failure/cancellation, and a newer clipboard winning a slow-download race. These tests need access to the macOS pasteboard service and pass outside the restricted test environment.

## Version 0.3.1 — faster, smaller previews, 26 October 2026

Gallery previews now use the standard MTP GetThumb operation (0x100A), forwarded by the transport coordinator. Missing thumbnails do not trigger a large original download. Only files up to 512 KB have an automatic original fallback; Open on Mac explicitly downloads other originals. Previews are downsampled to 640 pixels and the gallery window is smaller.

Automated checks cover a 40 MB photo preview with zero original downloads, missing and oversized device thumbnails, tiny-file fallback, selection changes, and safe dismissal. Build and transfer regression checks pass. After updating, the actual app reconnected to the X300 Pro and displayed a phone screenshot in the revised gallery. The implementation follows Android's GetThumb handling, including its GeneralError response for absent thumbnails: https://android.googlesource.com/platform/frameworks/av/+/7bca01a47344db605adc927f7b12b4e60310177f/media/mtp/MtpServer.cpp

## Version 0.3.0 — photo gallery, 26 October 2026

Added an in-app photo gallery with a large image preview, thumbnail strip, previous/next navigation, Space shortcut, double-clicking a photo name, and Open on Mac. Photo reads share the existing MTP transport and run serially. Closing the gallery waits for the current read before enabling other file actions. No phone originals are changed.

The release build and automated gallery checks pass, covering decoding, Unicode/uppercase extensions, rapid selection, serialized downloads, cache reuse, malformed images, the 100 MB preview limit, and safe dismissal. A separate sample-photo UI harness verified the rendered gallery, next-photo navigation, thumbnail selection, and the Open on Mac action. After reconnecting the X300 Pro, the actual app connected, browsed storage, and displayed a phone PNG in the gallery with all 12 folder thumbnails populated. The earlier upload/download verification below applies to version 0.2.0. A macOS accessibility recursion crash observed with the new selection-aware table menu was avoided by retaining the existing menu structure and photo-name double-click gesture.

Preview copies are downsampled to 2200 pixels; thumbnails to 180 pixels. The first 200 photos are prefetched. Cached originals target a 512 MB budget, excluding files retained for a receiving Mac app, and unused preview files are removed on dismissal. The first frame of animated images is displayed.

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
