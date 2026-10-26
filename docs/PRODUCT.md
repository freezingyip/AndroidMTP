# Product brief

Requested on 26 October 2026 (Hong Kong time).

## Goal

Build a Mac app for ordinary Android MTP file access. Use OpenMTP as a functional reference and AndroidFileSync as a visual reference. USB debugging is optional and adds extra tools; it must never be a prerequisite for normal file browsing or transfer.

## First version

The user can connect an unlocked phone in File transfer mode, select storage, browse folders, and transfer files in both directions. Include folder creation, rename, confirmed deletion, a visible transfer status, cancellation, and readable connection errors. Preserve Unicode names and use 64-bit transfer sizes. Do not silently replace existing files.

Use a familiar native Mac layout: storage and common folders in the sidebar, a main file list with name/size/date, breadcrumbs, upload/download actions, refresh, and transfer status. Respect system light and dark appearance.

## Optional debugging tools

Keep an explicit Advanced tools panel. The first optional feature is APK installation to an already-authorized ADB device. Future candidates are app management and wireless debugging/pairing. Explain unauthorized/offline device states. Do not enable debugging, accept the phone's authorization prompt, or select advanced mode automatically.

## Implementation boundaries

- Native SwiftUI app, a Swift service layer, and a small C bridge to libmtp.
- Serialize operations within the MTP session; never issue concurrent requests against the same session.
- Represent remote identity with device, storage, and object IDs. Displayed paths are UI breadcrumbs.
- Read only the selected directory instead of scanning every file on the phone at launch.
- Stage downloads locally and only move a completed result to its requested destination.
- Reject unsafe names and existing destinations. Refuse recursive deletion in the first version; empty folders can be deleted.
- Cancellation or disconnect may leave partial remote uploads. Report this without deleting unrelated content.
- Do not promise resume, a universal Android Trash, protected folder access, or more than the device's MTP implementation provides.

## Hardware acceptance

With USB debugging OFF: connect, browse internal storage/SD card, transfer a small test file both directions, create/rename/delete an empty test folder, cancel a transfer, reconnect after unplugging, and verify conflict behavior. Use user-approved disposable files for all write tests.

With debugging ON and the Mac approved: the optional APK panel recognizes the authorized device. Installing an APK is an explicit user action.

Check large files (>4 GB), low space, Unicode, empty folders, a locked phone, denied access, and another app claiming the MTP interface on real hardware before calling the app production-ready.
