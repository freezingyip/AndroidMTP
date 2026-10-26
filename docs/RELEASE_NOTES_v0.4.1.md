First public development prerelease of AndroidMTP, a native macOS file browser for Android.

- Standard USB MTP access without USB debugging.
- Internal storage and exposed SD cards, folder browsing, uploads/downloads, rename, folder creation, and confirmed deletion of files or empty folders.
- Finder Copy/Paste transfers with progress and cancellation.
- Small photo previews and a thumbnail strip, with original photos opened on demand.
- Optional ADB tools for an already-authorized device.
- Original app icon and MIT-licensed application code.

## Requirements and status

The supplied **arm64 / Apple Silicon** app requires **macOS 27.0 or newer** because of its bundled Homebrew libraries. It is **ad hoc signed, not Developer ID signed or notarized**. macOS may block opening the download. A signed/notarized release and verified Intel builds are future work. Source code targets macOS 13+, subject to the chosen toolchain and dependency builds.

Normal file access requires an unlocked Android phone, a data-capable USB cable, and USB File transfer mode. USB debugging is optional.

Verified on an X300 Pro: browsing, recursive transfers, Unicode and empty files/folders, reconnection, photo previews, and Finder Copy/Paste with matching downloaded file hashes. Physical multi-GB transfers and broader device coverage remain unverified. Cancellation can leave partial uploads. MTP has no universal Trash; this version refuses recursive deletion. Phones without Android's edit extensions have a 64 MB system-upload compatibility limit.

## Downloads

- `AndroidMTP-0.4.1-macOS-arm64.zip`: app with bundled libmtp/libusb, licenses, and dependency replacement instructions.
- `AndroidMTP-0.4.1-dependency-sources.zip`: complete upstream source archives for the bundled LGPL libraries, Homebrew build formulas, checksums, licenses, and rebuild instructions.
- `SHA256SUMS.txt`: SHA-256 checksums for both ZIP files.

Original app code and artwork: MIT. Bundled libmtp/libusb: LGPL-2.1-or-later. See the repository's third-party notices and dependency documentation.
