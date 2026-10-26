import AppKit
import Foundation

actor ClipboardTransport: MTPTransport {
    var uploads: [URL] = []
    var failDownload = false
    var delay: UInt64 = 0
    let file = RemoteItem(id: 1, parentID: UInt32.max, storageID: 1, name: "照片.txt", size: 7, modified: nil, isDirectory: false)
    let folder = RemoteItem(id: 2, parentID: UInt32.max, storageID: 1, name: "Folder", size: 0, modified: nil, isDirectory: true)
    func configure(fail: Bool = false, delay: UInt64 = 0) { failDownload = fail; self.delay = delay }
    func scan() async throws -> [DeviceInfo] { [DeviceInfo(id: "test", name: "Clipboard test", bus: 0, address: 0)] }
    func connect(_ device: DeviceInfo) async throws -> [StorageInfo] { [StorageInfo(id: 1, name: "Test", capacity: 1000, freeSpace: 500)] }
    func disconnect() async {}
    func list(storageID: UInt32, parentID: UInt32) async throws -> [RemoteItem] { [file, folder] }
    func createFolder(name: String, storageID: UInt32, parentID: UInt32) async throws {}
    func rename(_ item: RemoteItem, to name: String) async throws {}
    func delete(_ item: RemoteItem) async throws {}
    func upload(localURL: URL, storageID: UInt32, parentID: UInt32, progress: @escaping @Sendable (TransferUpdate) -> Void) async throws { uploads.append(localURL) }
    func download(_ item: RemoteItem, to url: URL, progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if failDownload { throw AndroidMTPError.message("Synthetic download failure") }
        if item.isDirectory { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        else { try Data("fixture".utf8).write(to: url) }
    }
    nonisolated func cancelTransfers() {}
}

@main struct ClipboardChecks {
    @MainActor static func main() async throws {
        let board = NSPasteboard(name: .init("AndroidMTP-ClipboardChecks-\(UUID())"))
        defer { board.releaseGlobally() }
        let transport = ClipboardTransport()
        let model = BrowserModel(service: transport, pasteboard: board)
        await model.scan(); await model.connectSelected()
        precondition(model.canAct)
        model.selection = [1, 2]
        await model.copySelection()
        let urls = model.clipboardFiles
        precondition(urls.count == 2 && Set(urls.map(\.lastPathComponent)) == ["照片.txt", "Folder"])
        let file = urls.first { $0.lastPathComponent == "照片.txt" }!
        let copiedBytes = try Data(contentsOf: file)
        precondition(copiedBytes == Data("fixture".utf8))
        precondition(model.status.contains("Paste in Finder"))
        await model.pasteFiles()
        let uploaded = await transport.uploads
        precondition(uploaded.count == 2, "Pasting copied files must upload all file URLs")
        board.clearContents(); board.setString("ordinary text", forType: .string)
        precondition(!model.canPasteFiles && model.clipboardFiles.isEmpty)
        await model.pasteFiles()
        let afterText = await transport.uploads.count
        precondition(afterText == 2, "Plain text must never be treated as a file path")
        await transport.configure(fail: true)
        model.selection = [1]
        await model.copySelection()
        precondition(board.string(forType: .string) == "ordinary text", "Failed copies must preserve the clipboard")
        model.errorMessage = nil
        await transport.configure(delay: 100_000_000)
        let copy = Task { await model.copySelection() }
        try await Task.sleep(nanoseconds: 20_000_000)
        board.clearContents(); board.setString("newer clipboard", forType: .string)
        await copy.value
        precondition(board.string(forType: .string) == "newer clipboard", "A slow copy must not overwrite a newer clipboard")
        precondition(model.status.contains("clipboard changed"))
        model.selection = [1, 2]
        let cancelledCopy = Task { await model.copySelection() }
        try await Task.sleep(nanoseconds: 20_000_000)
        model.cancelTransfers()
        await cancelledCopy.value
        precondition(board.string(forType: .string) == "newer clipboard", "Cancelled copies must not publish partial results")
        precondition(!model.isBusy && model.status.contains("cancelled"))
        // Retained clipboard copies are test-owned, so clean them up explicitly.
        if let directory = urls.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: directory) }
        print("Clipboard checks passed: multi-file/folder copies, Unicode names, download bytes, paste uploads, text rejection, failure/cancellation preservation, and clipboard change races.")
    }
}
