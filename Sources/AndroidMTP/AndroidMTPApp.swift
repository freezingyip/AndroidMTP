import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AndroidMTP", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

@main
struct AndroidMTPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = BrowserModel()

    var body: some Scene {
        WindowGroup("AndroidMTP") {
            BrowserView(model: model)
                .frame(minWidth: 920, minHeight: 600)
        }
        .defaultSize(width: 1120, height: 740)
        .commands {
            FileClipboardCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Folder", action: model.beginNewFolder)
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(!model.canAct)
            }
            CommandMenu("Transfer") {
                Button("Upload to Android…", action: model.chooseUploads)
                    .keyboardShortcut("u", modifiers: .command)
                    .disabled(!model.canAct)
                Button("Download to Mac…", action: model.chooseDownloadDestination)
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!model.canAct || model.selection.isEmpty)
                Divider()
                Button("Preview Photo Gallery") {
                    if let photo = model.selectedPhoto { model.previewPhoto(photo) }
                }
                    .keyboardShortcut(" ", modifiers: [])
                    .disabled(!model.canAct || model.selectedPhoto == nil)
                Button("Refresh") { Task { await model.refresh() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.canAct)
            }
        }
    }
}
