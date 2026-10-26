# Third-party components and references

AndroidMTP's application code is newly written for this project. No OpenMTP or AndroidFileSync application source has been copied.

## Runtime libraries

The preferred connection uses Apple's system-provided ImageCaptureCore framework. The PTP/MTP codec and service implementation are original project code using the public protocol layouts and platform APIs.

- libmtp — LGPL-2.1-or-later. Source: https://github.com/libmtp/libmtp . Homebrew: https://formulae.brew.sh/formula/libmtp .
- libusb — LGPL-2.1-or-later. Source: https://github.com/libusb/libusb . Homebrew: https://formulae.brew.sh/formula/libusb .

The development bundle dynamically links these libraries. The build copies the installed dependency license files when available. Distribution requires retaining the appropriate notices and providing the corresponding source/relinking information under the dependencies' licenses. This local development build is not a signed or notarized public release.

## Optional ADB

ADB is not redistributed. The optional tools use an existing local executable if found. Android platform-tools: https://developer.android.com/tools/releases/platform-tools .

## Reference projects

- OpenMTP: https://github.com/ganeshrvel/openmtp (MIT). Functional reference only.
- AndroidFileSync: https://github.com/Santosh7017/AndroidFileSync (GPL-3.0). Visual reference only; original SwiftUI implementation.

Reference-project licenses do not automatically cover all of their dependencies.
