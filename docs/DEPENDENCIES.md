# Bundled library sources and replacement

The preferred MTP connection uses the macOS ImageCaptureCore framework. The app also dynamically links libmtp and libusb for its direct-USB fallback. Their LGPL-2.1-or-later licenses are independent of the MIT license for AndroidMTP's original code.

## Version 0.4.1

- libmtp 1.1.23, with Homebrew's `--disable-mtpz` configuration.
- libusb 1.0.30.
- The shipped libraries are arm64 Homebrew builds for macOS 27.0. Their binary install names were adjusted for an app-local Frameworks folder; library source code was not changed.

The corresponding-source ZIP is published alongside the app at [the v0.4.1 prerelease](https://github.com/freezingyip/AndroidMTP/releases/tag/v0.4.1). It contains both complete upstream release source archives, the Homebrew build formulas used for those installed versions, the dependency manifest/checksums, this document, and license texts. `dependencies.json` records the upstream download URLs and SHA-256 values. The app ZIP and source ZIP are available from the same release.

## Build or replace the shared libraries

For an ordinary source build, install native Homebrew dependencies and run `scripts/build.sh`. Its packaging step copies the linked libraries into `AndroidMTP.app/Contents/Frameworks` and rewrites their dependency paths. The complete original app source and build scripts are available in this repository.

You can also compile the dependency source archives with their included configure scripts and Makefiles. For example, in a working folder containing the extracted libusb and libmtp directories:

```sh
thirdparty_prefix="$PWD/local-libraries"
cd libusb-1.0.30
./configure --disable-dependency-tracking --prefix="$thirdparty_prefix"
make
make install
cd ../libmtp-1.1.23
PKG_CONFIG_PATH="$thirdparty_prefix/lib/pkgconfig" ./configure \
  --prefix="$thirdparty_prefix" --disable-mtpz --disable-silent-rules
make
make install
```

Use native Apple Silicon tools for the supplied arm64 app, or rebuild the entire app and libraries for your target architecture. Further compiler/deployment settings depend on that target. The source archives contain the full upstream build documentation; the included Homebrew formulas record the distributed builds' additional configuration.

To use your replacement libraries with a copy of the supplied app:

1. Copy your rebuilt `libmtp.9.dylib` and `libusb-1.0.0.dylib` into that copy's `Contents/Frameworks`, keeping these filenames.
2. Set each library's install ID with `install_name_tool -id @rpath/<filename> <library-path>`.
3. Inspect `libmtp.9.dylib` with `otool -L`. Change its libusb dependency from your build prefix to `@loader_path/libusb-1.0.0.dylib` using `install_name_tool -change <old-path> @loader_path/libusb-1.0.0.dylib <libmtp-path>`.
4. Ad hoc sign the two replaced libraries and then the app copy using `codesign --force --sign - <path>` for each. This repairs signatures invalidated by your modifications; it does not notarize the app.

The executable already loads its shared libraries through `@executable_path/../Frameworks`. No application restriction is imposed on modifying or replacing these libraries or debugging those modifications. Keep the required dependency notices with redistributed versions. No ADB binary is bundled.
