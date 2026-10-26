## Download and install

**[Download AndroidMTP for Mac](https://github.com/freezingyip/AndroidMTP/releases/download/v0.5.0/AndroidMTP-0.5.0.dmg)**

1. Open **AndroidMTP-0.5.0.dmg**.
2. Drag **AndroidMTP** onto **Applications**.
3. Open **Applications → AndroidMTP**.

**Apple Silicon · macOS 13+ · No Homebrew or Terminal commands.**

### First opening

This community preview has not been notarized because the project does not yet have an Apple Developer ID certificate. If macOS blocks it and you choose to trust this download, open **System Settings → Privacy & Security**, find AndroidMTP, and choose **Open Anyway**. See [Apple’s instructions](https://support.apple.com/en-hk/102445). No security setting is changed by the installer.

### What changed

- A drag-to-Applications DMG, with an Applications shortcut and a local installation guide.
- A direct installer download at the top of the project README.
- Rebuilt libusb and libmtp for macOS 13, removing the previous package’s macOS 27 requirement. The current live device verification is on macOS 27; older macOS versions and Intel Macs have not yet been verified.
- All existing MTP browsing, transfers, Finder Copy/Paste, small photo previews, and optional ADB features remain available.

The mounted DMG, app copy, code signatures, library dependency paths, and regression suite were verified. Physical multi-GB transfers and broader phone coverage remain unverified. Failed or cancelled uploads can leave partial content on Android. This version deletes only files and empty folders.

### Optional developer downloads

The app ZIP is an alternative to the DMG. The dependency-source ZIP contains the exact libusb/libmtp sources, build recipe, license texts, and source checksums. `SHA256SUMS.txt` covers the DMG and ZIPs. You do not need these additional files for normal installation.

Original app code/artwork: MIT. Bundled libmtp/libusb: LGPL-2.1-or-later.
