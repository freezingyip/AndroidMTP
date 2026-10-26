# AndroidMTP

A native Mac file browser for Android phones. Standard USB **MTP / File transfer** is the default connection; **USB debugging is not required** for normal file access. Version 0.2.0 uses the macOS device service so Photos and OneDrive can keep running.

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

Run `./scripts/test.sh` for hardware-free checks of file safety, atomic download completion, cancellation, 64-bit values, PTP codecs, transport routing, recursive chunked transfers, ADB parsing, and APK preflight. The optional `./scripts/test.sh --xctest` suite needs an Xcode toolchain with XCTest.

For an optional live-device check, `./scripts/device-check.sh` prepares four harmless local files (including a 5 MB binary and an empty file) and builds the test executable. Run `.build/device-check/roundtrip .build/device-test` with exactly one unlocked phone connected. This explicitly uploads a test folder, renames it, downloads it, checks file hashes, and leaves the test folder on Android. It does not delete or replace existing phone files. It uses the same transport selection as the app.

## Connect a phone

1. Connect an unlocked Android phone with a data-capable USB cable.
2. On the phone, choose **File transfer / Android Auto** (wording varies) and allow file access if prompted.
3. In AndroidMTP, click **Connect Android**, scan, choose the phone, and connect.

The default connection sends normal MTP commands through Apple's ImageCaptureCore service. It cooperates with the photo-import service rather than competing for its exclusive USB interface. A direct libmtp fallback is retained for devices macOS does not discover; that fallback may still require exclusive USB access. Connection errors appear next to the controls. See `docs/STATUS.md` for actual-app and live-device verification.

Standard MTP only exposes the storage Android makes available. Protected app data and restricted Android folders may remain inaccessible. Enabling ADB does not grant root or promise access to private app data.

## References

- [OpenMTP](https://github.com/ganeshrvel/openmtp): MTP workflow and compatibility reference. Its current Kalam backend is separate from this implementation.
- [AndroidFileSync](https://github.com/Santosh7017/AndroidFileSync): native macOS UI reference. This project uses original UI code.
- [ImageCaptureCore](https://developer.apple.com/documentation/imagecapturecore): system-managed PTP/MTP connection.
- [libmtp](https://github.com/libmtp/libmtp): direct USB fallback through a small C bridge and protocol layout reference.
- [Android ADB documentation](https://developer.android.com/tools/adb): optional debugging features and computer authorization.

See [the product brief](docs/PRODUCT.md), [development status](docs/STATUS.md), and [third-party notes](THIRD_PARTY_NOTICES.md).
