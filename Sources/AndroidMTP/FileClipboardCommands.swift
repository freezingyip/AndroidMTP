import AppKit
import SwiftUI

struct FileClipboardCommands: Commands {
    @FocusedObject private var browser: BrowserModel?

    var body: some Commands {
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(browser != nil)
            Button("Copy") {
                if let browser { Task { await browser.copySelection() } }
                else { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
            }
            .keyboardShortcut("c", modifiers: .command)
            .disabled(browser.map { !$0.canAct || $0.selection.isEmpty } ?? false)
            Button("Paste") {
                if let browser { Task { await browser.pasteFiles() } }
                else { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
            }
            .keyboardShortcut("v", modifiers: .command)
            .disabled(browser.map { !$0.canPasteFiles } ?? false)
            Divider()
            Button("Select All") {
                if let browser { browser.selection = Set(browser.filteredItems.map(\.id)) }
                else { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
            }
            .keyboardShortcut("a", modifiers: .command)
            .disabled(browser.map { !$0.canAct } ?? false)
        }
    }
}
