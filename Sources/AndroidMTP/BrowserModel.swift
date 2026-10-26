import AppKit
import AndroidMTPCore
import Foundation

@MainActor
final class BrowserModel: ObservableObject {
    @Published var devices: [DeviceInfo] = []
    @Published var selectedDeviceID: String?
    @Published private(set) var activeDevice: DeviceInfo?
    @Published private(set) var storages: [StorageInfo] = []
    @Published private(set) var storageID: UInt32?
    @Published private(set) var path: [RemoteItem] = []
    @Published private(set) var items: [RemoteItem] = []
    @Published private(set) var rootFolders: [RemoteItem] = []
    @Published var selection: Set<UInt32> = []
    @Published var search = ""
    @Published var isDropTarget = false
    @Published private(set) var clipboardRevision = 0
    @Published private(set) var isBusy = false
    @Published private(set) var isTransferring = false
    @Published private(set) var status = "Ready to connect"
    @Published private(set) var transferName = ""
    @Published private(set) var transferProgress: Double = 0
    @Published private(set) var transferBytes = ""
    @Published var errorMessage: String?
    @Published private(set) var connectionError: String?
    @Published var showConnectionSheet = false
    @Published var showAdvancedSheet = false
    @Published var namePrompt: NamePrompt?
    @Published var proposedName = ""
    @Published var showDeleteConfirmation = false

    @Published var showPhotoGallery = false
    private(set) var photoGallery: PhotoGalleryModel?

    private let pasteboard: NSPasteboard
    private let service: any MTPTransport
    private var cancelled = false
    private var activeTransferID: UUID?

    init(service: any MTPTransport = DeviceFileService(), pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.service = service
    }

    enum NamePrompt: String, Identifiable {
        case newFolder, rename
        var id: String { rawValue }
        var title: String { self == .newFolder ? "New folder" : "Rename item" }
    }

    var currentStorage: StorageInfo? { storages.first { $0.id == storageID } }
    var parentID: UInt32 { path.last?.id ?? UInt32.max }
    var isConnected: Bool { activeDevice != nil && storageID != nil }
    var canAct: Bool { isConnected && !isBusy && !showAdvancedSheet && !showConnectionSheet }
    var selectedItems: [RemoteItem] { items.filter { selection.contains($0.id) } }
    var currentFolderName: String { path.last?.name ?? currentStorage?.name ?? "Android" }
    var filteredItems: [RemoteItem] {
        items.filter { search.isEmpty || $0.name.localizedStandardContains(search) }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }
    var quickFolders: [RemoteItem] {
        let names = ["DCIM", "Download", "Downloads", "Pictures", "Music", "Movies", "Documents"]
        return names.compactMap { name in rootFolders.first { $0.name == name } }
    }

    func scan() async {
        guard !isBusy, activeDevice == nil else { return }
        connectionError = nil
        errorMessage = nil
        isBusy = true
        status = "Looking for Android devices…"
        defer { isBusy = false }
        do {
            devices = try await service.scan()
            selectedDeviceID = devices.first?.id
            status = devices.isEmpty ? "No MTP devices found" : "Choose a device to connect"
        } catch {
            devices = []
            selectedDeviceID = nil
            status = "Device scan could not finish"
            connectionError = error.localizedDescription
        }
    }

    func connectSelected() async {
        guard !isBusy else { return }
        connectionError = nil
        errorMessage = nil
        guard let device = devices.first(where: { $0.id == selectedDeviceID }) else {
            status = "Choose a device to connect"
            connectionError = "Select an available device, or scan again if your phone has reconnected."
            return
        }
        isBusy = true
        status = "Connecting to \(device.name)…"
        defer { isBusy = false }
        do {
            let connectedStorages = try await service.connect(device)
            guard let firstStorage = connectedStorages.first else {
                throw AndroidMTPError.message("Your phone is connected but has no accessible storage. Unlock it, choose USB File transfer, and reconnect.")
            }
            let root = try await service.list(storageID: firstStorage.id, parentID: UInt32.max)
            storages = connectedStorages
            storageID = firstStorage.id
            path = []
            items = root
            rootFolders = root.filter(\.isDirectory)
            selection = []
            search = ""
            activeDevice = device
            status = "Connected via USB MTP"
            showConnectionSheet = false
        } catch {
            await service.disconnect()
            status = "Connection could not finish"
            connectionError = error.localizedDescription
        }
    }

    func disconnect() async {
        guard !isBusy else { return }
        isBusy = true
        await service.disconnect()
        activeDevice = nil
        storages = []
        storageID = nil
        path = []
        items = []
        rootFolders = []
        selection = []
        search = ""
        status = "Disconnected"
        isBusy = false
    }

    func openStorage(_ storage: StorageInfo) async {
        guard canAct else { return }
        await navigate(storage: storage.id, newPath: [])
    }

    func openFolder(_ item: RemoteItem) async {
        guard canAct, item.isDirectory else { return }
        await navigate(storage: item.storageID, newPath: path + [item])
    }

    func openQuickFolder(_ item: RemoteItem) async {
        guard canAct else { return }
        await navigate(storage: item.storageID, newPath: [item])
    }

    func openSelection() async {
        guard selectedItems.count == 1, let item = selectedItems.first else { return }
        if item.isDirectory { await openFolder(item) }
        else if PhotoGalleryModel.isPhoto(item) { previewPhoto(item) }
    }

    var selectedPhoto: RemoteItem? {
        selectedItems.count == 1 ? selectedItems.first.flatMap { PhotoGalleryModel.isPhoto($0) ? $0 : nil } : nil
    }

    func previewPhoto(_ item: RemoteItem, openOnMac: Bool = false) {
        guard canAct, PhotoGalleryModel.isPhoto(item) else { return }
        let photos = filteredItems.filter(PhotoGalleryModel.isPhoto)
        guard photos.contains(where: { $0.id == item.id }) else { return }
        let gallery = PhotoGalleryModel(photos: photos, selected: item, service: service)
        photoGallery = gallery
        isBusy = true
        showPhotoGallery = true
        if openOnMac { gallery.openOnMac() }
    }

    func closePhotoGallery() async {
        await photoGallery?.finish()
        photoGallery = nil
        isBusy = false
    }

    func goToBreadcrumb(_ count: Int) async {
        guard canAct, let storageID else { return }
        await navigate(storage: storageID, newPath: Array(path.prefix(count)))
    }

    private func navigate(storage: UInt32, newPath: [RemoteItem]) async {
        isBusy = true
        status = "Loading folder…"
        defer { isBusy = false }
        do {
            let listing = try await service.list(storageID: storage, parentID: newPath.last?.id ?? UInt32.max)
            storageID = storage
            path = newPath
            items = listing
            if newPath.isEmpty { rootFolders = listing.filter(\.isDirectory) }
            selection = []
            search = ""
            status = "Connected via USB MTP"
        } catch { report(error) }
    }

    func refresh() async {
        guard canAct, let storageID else { return }
        await navigate(storage: storageID, newPath: path)
    }

    func beginNewFolder() {
        guard canAct else { return }
        proposedName = "Untitled Folder"
        namePrompt = .newFolder
    }

    func beginRename() {
        guard canAct, selectedItems.count == 1, let item = selectedItems.first else { return }
        proposedName = item.name
        namePrompt = .rename
    }

    func saveName() async {
        guard canAct, let prompt = namePrompt, let storageID else { return }
        let name = proposedName
        let item = selectedItems.first
        isBusy = true
        namePrompt = nil
        status = prompt == .newFolder ? "Creating folder…" : "Renaming item…"
        defer { isBusy = false }
        do {
            if prompt == .newFolder {
                try await service.createFolder(name: name, storageID: storageID, parentID: parentID)
            } else if let item {
                try await service.rename(item, to: name)
            }
            try await reloadItems()
            status = prompt == .newFolder ? "Folder created" : "Item renamed"
        } catch { report(error) }
    }

    func deleteSelection() async {
        guard canAct else { return }
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        isBusy = true
        status = "Deleting selected items…"
        defer { isBusy = false }
        do {
            for item in targets { try await service.delete(item) }
            try await reloadItems()
            status = "Deleted \(targets.count) item\(targets.count == 1 ? "" : "s")"
        } catch {
            report(error)
            try? await reloadItems()
        }
    }

    func chooseUploads() {
        guard canAct else { return }
        let panel = NSOpenPanel()
        panel.title = "Upload to \(currentFolderName)"
        panel.prompt = "Upload"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose files or folders to copy to your Android device. Existing items will not be replaced."
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await upload(urls) }
        }
    }

    func upload(_ urls: [URL]) async {
        guard canAct, let storageID, !urls.isEmpty else { return }
        let folder = parentID
        await performTransfers(names: urls.map(\.lastPathComponent), isUpload: true) { index, progress in
            try await self.service.upload(localURL: urls[index], storageID: storageID, parentID: folder, progress: progress)
        }
    }

    func clipboardDidChange() { clipboardRevision = pasteboard.changeCount }

    var clipboardFiles: [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? [])
            .compactMap { ($0 as? NSURL).map { $0 as URL } }.filter(\.isFileURL)
    }

    var canPasteFiles: Bool {
        _ = clipboardRevision
        return canAct && !clipboardFiles.isEmpty
    }

    func pasteFiles() async {
        guard canAct else { return }
        let urls = clipboardFiles
        guard !urls.isEmpty else { status = "Copy files in Finder first, then paste here to upload."; return }
        await upload(urls)
    }

    func copySelection() async {
        guard canAct else { return }
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let clipboardVersion = pasteboard.changeCount
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AndroidMTP-Clipboard-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            let completed = await performTransfers(names: targets.map(\.name), isUpload: false) { index, progress in
                let item = targets[index]
                guard !item.name.isEmpty, item.name != ".", item.name != "..", !item.name.contains("/"), !item.name.contains("\0") else {
                    throw AndroidMTPError.message("This file has an invalid name and cannot be copied.")
                }
                try await self.service.download(item, to: directory.appendingPathComponent(item.name), progress: progress)
            }
            guard completed else { try? FileManager.default.removeItem(at: directory); return }
            // Do not replace something the user copied while the USB download was running.
            guard pasteboard.changeCount == clipboardVersion else {
                try? FileManager.default.removeItem(at: directory)
                status = "The clipboard changed while downloading. Select Copy again to copy these files."
                return
            }
            let urls = targets.map { directory.appendingPathComponent($0.name) as NSURL }
            pasteboard.clearContents()
            guard pasteboard.writeObjects(urls) else {
                throw AndroidMTPError.message("Could not place the downloaded files on the clipboard. Try Copy again.")
            }
            clipboardDidChange()
            status = "Copied \(targets.count) item\(targets.count == 1 ? "" : "s"). Paste in Finder to save to your Mac."
            // Keep successful clipboard files available after disconnect/quit for Finder paste.
            // macOS manages their temporary directory; phone originals are unchanged.
        } catch {
            try? FileManager.default.removeItem(at: directory)
            report(error)
        }
    }

    func chooseDownloadDestination() {
        guard canAct else { return }
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.title = "Download to your Mac"
        panel.prompt = "Download here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose a destination folder. Existing files will not be replaced."
        if panel.runModal() == .OK, let directory = panel.url {
            Task {
                await performTransfers(names: targets.map(\.name), isUpload: false) { index, progress in
                    let item = targets[index]
                    try await self.service.download(item, to: directory.appendingPathComponent(item.name), progress: progress)
                }
            }
        }
    }

    @discardableResult
    private func performTransfers(names: [String], isUpload: Bool, operation: (Int, @escaping @Sendable (TransferUpdate) -> Void) async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        isTransferring = true
        cancelled = false
        defer {
            activeTransferID = nil
            isBusy = false
            isTransferring = false
        }
        var finished = 0
        var transferFailed = false
        let partialUploadWarning = "A partial upload may remain on Android."
        let cancellationStatus = isUpload ? "Transfer cancelled. \(partialUploadWarning)" : "Transfer cancelled"
        do {
            for index in names.indices {
                if cancelled { break }
                let token = UUID()
                activeTransferID = token
                transferName = names[index]
                transferProgress = 0
                transferBytes = "Preparing…"
                status = "Transferring \(index + 1) of \(names.count)"
                try await operation(index) { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self, self.activeTransferID == token else { return }
                        self.transferProgress = update.fraction
                        self.transferBytes = "\(Self.byteCount(update.completed)) of \(Self.byteCount(update.total))"
                    }
                }
                finished += 1
            }
            status = cancelled ? cancellationStatus : "Transferred \(finished) item\(finished == 1 ? "" : "s")"
        } catch {
            transferFailed = true
            if cancelled { status = cancellationStatus }
            else {
                let details = error.localizedDescription
                let message = isUpload && !details.localizedCaseInsensitiveContains("partial upload")
                    ? "\(details)\n\n\(partialUploadWarning)" : details
                report(AndroidMTPError.message(message))
            }
        }
        activeTransferID = nil
        do { try await reloadItems() }
        catch { if !cancelled && !transferFailed { report(error) } }
        return !cancelled && !transferFailed && finished == names.count
    }

    func cancelTransfers() {
        guard isTransferring else { return }
        cancelled = true
        status = "Cancelling transfer…"
        service.cancelTransfers()
    }

    private func reloadItems() async throws {
        guard let storageID else { return }
        items = try await service.list(storageID: storageID, parentID: parentID)
        if path.isEmpty { rootFolders = items.filter(\.isDirectory) }
        selection.formIntersection(Set(items.map(\.id)))
    }

    private func report(_ error: Error) {
        status = "Operation could not finish"
        errorMessage = error.localizedDescription
    }

    static func byteCount(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}
