# AndroidMTP

A native Mac file browser for Android phones. Standard USB **MTP / File transfer** is the default connection; **USB debugging is not required** for normal file access.

## Product direction

- Browse the internal storage and SD cards exposed by the phone.
- Upload and download files and folders, create folders, rename items, and delete with confirmation.
- Use a native sidebar, file list, breadcrumbs, toolbar, and transfer status inspired by the familiar layout of AndroidFileSync.
- Offer extra ADB tools separately, only when the user explicitly chooses them and authorizes their computer on Android.
- Keep transfers local. No account, cloud service, or phone companion app.

## Development

Requirements: macOS 13 or newer, Apple's Command Line Tools with Swift 5.9 or newer, and native Homebrew libraries.

```sh
brew install libmtp pkgconf
./scripts/build.sh
open build/AndroidMTP.app
```

The build script builds the app and copies its MTP libraries into the local app bundle. The source targets macOS 13+, but the packaged app's minimum OS also follows the installed Homebrew libraries. This development bundle is built for this Mac. It uses ad-hoc signing; public distribution will need a proper release process.

Run `./scripts/test.sh` for hardware-free checks of file safety, atomic download completion, cancellation state, 64-bit progress, ADB parsing, and APK preflight. The optional `./scripts/test.sh --xctest` suite needs an Xcode toolchain with XCTest.

For an optional live-device check, `./scripts/device-check.sh` prepares three harmless local files and builds the test executable. Close AndroidMTP and other MTP sessions, then run `.build/device-check/roundtrip .build/device-test` with exactly one unlocked phone connected. This explicitly uploads a small test folder, renames it, downloads it, checks file hashes, and leaves the test folder on Android. It does not delete or replace existing phone files.

## Connect a phone

1. Connect an unlocked Android phone with a data-capable USB cable.
2. On the phone, choose **File transfer / Android Auto** (wording varies) and allow file access if prompted.
3. Close other MTP file browsers if they are using the same phone.
4. In AndroidMTP, click **Connect**, scan, and choose the phone.

If the phone is detected but will not open, Photos, Image Capture, or a photo-importing cloud client may already own its USB interface. Finish any imports, quit the conflicting app, unplug/reconnect the phone, and try again. Connection errors appear next to the connection controls. See `docs/STATUS.md` for this Mac's verification results, including the successful hardware round-trip.

Standard MTP only exposes the storage Android makes available. Protected app data and restricted Android folders may remain inaccessible. Enabling ADB does not grant root or promise access to private app data.

## References

- [OpenMTP](https://github.com/ganeshrvel/openmtp): MTP workflow and compatibility reference. Its current Kalam backend is separate from this implementation.
- [AndroidFileSync](https://github.com/Santosh7017/AndroidFileSync): native macOS UI reference. This project uses original UI code.
- [libmtp](https://github.com/libmtp/libmtp): standard MTP transport used through a small C bridge.
- [Android ADB documentation](https://developer.android.com/tools/adb): optional debugging features and computer authorization.

See [the product brief](docs/PRODUCT.md), [development status](docs/STATUS.md), and [third-party notes](THIRD_PARTY_NOTICES.md).
