import CAndroidMTP
import Darwin
import Foundation

/// File names supplied by a device are data, never a path to write directly.
enum FileSafety {
    static func validateName(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\0") else {
            throw AndroidMTPError.message("This item has an unsafe file name and cannot be transferred.")
        }
    }

    static func destination(directory: URL, name: String) throws -> URL {
        try validateName(name)
        guard directory.isFileURL else {
            throw AndroidMTPError.message("Choose a local download folder.")
        }
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AndroidMTPError.message("The destination folder is unavailable.")
        }
        let result = base.appendingPathComponent(name).standardizedFileURL
        guard result.deletingLastPathComponent().path == base.path else {
            throw AndroidMTPError.message("The file name escapes the destination folder.")
        }
        guard try !itemExists(at: result) else {
            throw AndroidMTPError.message("“\(name)” already exists. Choose another name or destination.")
        }
        return result
    }

    static func itemExists(at url: URL) throws -> Bool {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        if result == 0 { return true }
        if errno == ENOENT { return false }
        throw AndroidMTPError.message("Could not inspect the destination: \(String(cString: strerror(errno))).")
    }

    /// Conservative collision matching also protects common case-insensitive Mac volumes.
    static func collisionKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

private final class TransferCancellation: @unchecked Sendable {
    let pointer: OpaquePointer

    init() {
        guard let pointer = amtp_cancellation_create() else {
            fatalError("Unable to allocate transfer cancellation state.")
        }
        self.pointer = pointer
    }

    deinit { amtp_cancellation_free(pointer) }
    func reset() { amtp_cancellation_reset(pointer) }
    func cancel() { amtp_cancellation_cancel(pointer) }
    var isCancelled: Bool { amtp_cancellation_is_cancelled(pointer) != 0 }
}

private final class ProgressContext {
    let base: UInt64
    let total: UInt64
    let callback: @Sendable (TransferUpdate) -> Void
    private var lastEmission: UInt64 = 0

    init(base: UInt64, total: UInt64, callback: @escaping @Sendable (TransferUpdate) -> Void) {
        self.base = base; self.total = total; self.callback = callback
    }

    func update(completed: UInt64) {
        let now = DispatchTime.now().uptimeNanoseconds
        let (sum, overflow) = base.addingReportingOverflow(completed)
        let value = overflow ? total : min(sum, total)
        guard lastEmission == 0 || now - lastEmission >= 100_000_000 || value == total else { return }
        lastEmission = now
        callback(TransferUpdate(completed: value, total: total))
    }
}

private let progressCallback: AMTPProgress = { completed, _, pointer in
    guard let pointer else { return }
    Unmanaged<ProgressContext>.fromOpaque(pointer).takeUnretainedValue().update(completed: completed)
}

private struct UploadNode {
    let url: URL
    let name: String
    let size: UInt64
    let children: [UploadNode]?
}

private struct DownloadNode {
    let item: RemoteItem
    let children: [DownloadNode]?
}

/// A device owns one MTP transaction stream. Keep its blocking native calls on this actor.
public actor MTPService {
    private var session: OpaquePointer?
    private nonisolated let cancellation = TransferCancellation()

    public init() {}

    deinit { if let session { amtp_disconnect(session) } }

    public func scan() async throws -> [DeviceInfo] {
        var devices: UnsafeMutablePointer<AMTPDevice>?
        var count = 0
        var error: UnsafeMutablePointer<CChar>?
        let result = amtp_scan(&devices, &count, &error)
        defer { amtp_free_devices(devices, count) }
        try check(result, error: error)
        guard let devices else { return [] }
        return (0..<count).map { index in
            let entry = devices[index]
            return DeviceInfo(id: "\(entry.bus)-\(entry.address)", name: string(entry.name),
                              bus: entry.bus, address: entry.address)
        }
    }

    public func connect(_ device: DeviceInfo) async throws -> [StorageInfo] {
        closeSession()
        var error: UnsafeMutablePointer<CChar>?
        guard let opened = amtp_connect(device.bus, device.address, &error) else {
            try check(-1, error: error)
            throw AndroidMTPError.message("Could not connect to the device.")
        }
        if let error { amtp_free_error(error) }
        session = opened
        do { return try readStorages() }
        catch { closeSession(); throw error }
    }

    public func disconnect() async { closeSession() }

    public nonisolated func cancelTransfers() { cancellation.cancel() }

    public func list(storageID: UInt32, parentID: UInt32) async throws -> [RemoteItem] {
        try readItems(storageID: storageID, parentID: parentID)
    }

    public func createFolder(name: String, storageID: UInt32, parentID: UInt32) async throws {
        _ = try makeFolder(name: name, storageID: storageID, parentID: parentID)
    }

    public func rename(_ item: RemoteItem, to name: String) async throws {
        try FileSafety.validateName(name)
        if item.name == name { return }
        try requireUnusedName(name, storageID: item.storageID, parentID: item.parentID, excluding: item.id)
        var error: UnsafeMutablePointer<CChar>?
        let result = amtp_rename(try requireSession(), item.id, name, &error)
        try check(result, error: error)
    }

    public func delete(_ item: RemoteItem) async throws {
        if item.isDirectory {
            let children = try readItems(storageID: item.storageID, parentID: item.id)
            guard children.isEmpty else {
                throw AndroidMTPError.message("This folder is not empty. Delete its contents separately before deleting the folder.")
            }
        }
        var error: UnsafeMutablePointer<CChar>?
        let result = amtp_delete(try requireSession(), item.id, &error)
        try check(result, error: error)
    }

    public func upload(localURL: URL, storageID: UInt32, parentID: UInt32,
                       progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        _ = try requireSession()
        cancellation.reset()
        try checkCancelled()
        let node = try prepareUpload(localURL, depth: 0)
        try requireUnusedName(node.name, storageID: storageID, parentID: parentID)
        let total = try uploadSize(node)
        progress(TransferUpdate(completed: 0, total: total))
        var completed: UInt64 = 0
        try send(node, storageID: storageID, parentID: parentID,
                 completed: &completed, total: total, progress: progress)
        try checkCancelled()
        progress(TransferUpdate(completed: total, total: total))
    }

    public func download(_ item: RemoteItem, to localURL: URL,
                         progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        _ = try requireSession()
        cancellation.reset()
        try FileSafety.validateName(item.name)
        guard localURL.isFileURL else { throw AndroidMTPError.message("Choose a local destination.") }
        let destination = try FileSafety.destination(directory: localURL.deletingLastPathComponent(), name: localURL.lastPathComponent)
        var seen = Set<UInt32>()
        let node = try prepareDownload(item, seen: &seen, depth: 0)
        let total = try downloadSize(node)
        progress(TransferUpdate(completed: 0, total: total))
        let staging = try FileSafety.destination(directory: destination.deletingLastPathComponent(), name: ".AndroidMTP-\(UUID().uuidString).partial")
        // mkdir is exclusive: an existing path is never mistaken for our own staging area.
        let created = staging.path.withCString { Darwin.mkdir($0, 0o700) }
        guard created == 0 else {
            throw AndroidMTPError.message("Could not create a private download folder: \(String(cString: strerror(errno))).")
        }
        defer { try? FileManager.default.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload")
        var completed: UInt64 = 0
        try receive(node, at: payload, completed: &completed, total: total, progress: progress)
        try checkCancelled()
        var error: UnsafeMutablePointer<CChar>?
        let result = amtp_move_no_replace(payload.path, destination.path, &error)
        try check(result, error: error)
        progress(TransferUpdate(completed: total, total: total))
    }

    private func closeSession() {
        if let session { amtp_disconnect(session) }
        session = nil
    }

    private func requireSession() throws -> OpaquePointer {
        guard let session else { throw AndroidMTPError.message("Connect an Android device first.") }
        return session
    }

    private func readStorages() throws -> [StorageInfo] {
        var storages: UnsafeMutablePointer<AMTPStorage>?
        var count = 0
        var error: UnsafeMutablePointer<CChar>?
        let result = amtp_storages(try requireSession(), &storages, &count, &error)
        defer { amtp_free_storages(storages, count) }
        try check(result, error: error)
        guard let storages else { return [] }
        return (0..<count).map { index in
            let entry = storages[index]
            return StorageInfo(id: entry.id, name: string(entry.name), capacity: entry.capacity, freeSpace: entry.free_space)
        }
    }

    private func readItems(storageID: UInt32, parentID: UInt32) throws -> [RemoteItem] {
        var items: UnsafeMutablePointer<AMTPItem>?
        var count = 0
        var error: UnsafeMutablePointer<CChar>?
        let result = amtp_list(try requireSession(), storageID, parentID, &items, &count, &error)
        defer { amtp_free_items(items, count) }
        try check(result, error: error)
        guard let items else { return [] }
        return (0..<count).map { index in
            let entry = items[index]
            return RemoteItem(id: entry.id, parentID: entry.parent_id, storageID: entry.storage_id,
                              name: string(entry.name), size: entry.size,
                              modified: entry.modified > 0 ? Date(timeIntervalSince1970: Double(entry.modified)) : nil,
                              isDirectory: entry.is_directory != 0)
        }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func requireUnusedName(_ name: String, storageID: UInt32, parentID: UInt32, excluding: UInt32? = nil) throws {
        try FileSafety.validateName(name)
        let key = FileSafety.collisionKey(name)
        let items = try readItems(storageID: storageID, parentID: parentID)
        guard !items.contains(where: { $0.id != excluding && FileSafety.collisionKey($0.name) == key }) else {
            throw AndroidMTPError.message("“\(name)” already exists on the phone. Rename it or choose another folder.")
        }
    }

    private func makeFolder(name: String, storageID: UInt32, parentID: UInt32) throws -> UInt32 {
        try requireUnusedName(name, storageID: storageID, parentID: parentID)
        var id: UInt32 = 0
        var error: UnsafeMutablePointer<CChar>?
        let result = amtp_create_folder(try requireSession(), name, storageID, parentID, &id, &error)
        try check(result, error: error)
        return id
    }

    private func prepareUpload(_ url: URL, depth: Int) throws -> UploadNode {
        try checkCancelled()
        guard url.isFileURL, depth < 256 else {
            throw AndroidMTPError.message("The upload contains an invalid path or too many nested folders.")
        }
        let name = url.lastPathComponent
        try FileSafety.validateName(name)
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard info.isSymbolicLink != true else {
            throw AndroidMTPError.message("Symbolic links are not uploaded: “\(name)”.")
        }
        if info.isDirectory == true {
            let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            var names = Set<String>()
            let nodes = try children.map { child in
                guard names.insert(FileSafety.collisionKey(child.lastPathComponent)).inserted else {
                    throw AndroidMTPError.message("This folder contains names that may collide on the destination: “\(child.lastPathComponent)”.")
                }
                return try prepareUpload(child, depth: depth + 1)
            }
            return UploadNode(url: url, name: name, size: 0, children: nodes)
        }
        guard info.isRegularFile == true, let size = info.fileSize, size >= 0 else {
            throw AndroidMTPError.message("“\(name)” is not a readable regular file.")
        }
        return UploadNode(url: url, name: name, size: UInt64(size), children: nil)
    }

    private func prepareDownload(_ item: RemoteItem, seen: inout Set<UInt32>, depth: Int) throws -> DownloadNode {
        try checkCancelled()
        try FileSafety.validateName(item.name)
        guard depth < 256, seen.insert(item.id).inserted else {
            throw AndroidMTPError.message("The phone returned a repeated item or an excessively nested folder.")
        }
        guard item.isDirectory else { return DownloadNode(item: item, children: nil) }
        let items = try readItems(storageID: item.storageID, parentID: item.id)
        var names = Set<String>()
        var children: [DownloadNode] = []
        for child in items {
            guard names.insert(FileSafety.collisionKey(child.name)).inserted else {
                throw AndroidMTPError.message("This folder contains names that would collide on your Mac: “\(child.name)”.")
            }
            children.append(try prepareDownload(child, seen: &seen, depth: depth + 1))
        }
        return DownloadNode(item: item, children: children)
    }

    private func uploadSize(_ node: UploadNode) throws -> UInt64 {
        guard let children = node.children else { return node.size }
        return try children.reduce(0) { try safeAdd($0, uploadSize($1)) }
    }

    private func downloadSize(_ node: DownloadNode) throws -> UInt64 {
        guard let children = node.children else { return node.item.size }
        return try children.reduce(0) { try safeAdd($0, downloadSize($1)) }
    }

    private func safeAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw AndroidMTPError.message("The total transfer size is too large.") }
        return value
    }

    private func send(_ node: UploadNode, storageID: UInt32, parentID: UInt32,
                      completed: inout UInt64, total: UInt64,
                      progress: @escaping @Sendable (TransferUpdate) -> Void) throws {
        try checkCancelled()
        if let children = node.children {
            let parent = try makeFolder(name: node.name, storageID: storageID, parentID: parentID)
            for child in children {
                try send(child, storageID: storageID, parentID: parent,
                         completed: &completed, total: total, progress: progress)
            }
            return
        }
        try requireUnusedName(node.name, storageID: storageID, parentID: parentID)
        let context = ProgressContext(base: completed, total: total, callback: progress)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        var error: UnsafeMutablePointer<CChar>?
        let result = withExtendedLifetime(context) {
            amtp_upload(session, node.url.path, node.name, storageID, parentID,
                        cancellation.pointer, progressCallback, pointer, &error)
        }
        try check(result, error: error)
        completed = try safeAdd(completed, node.size)
        progress(TransferUpdate(completed: min(completed, total), total: total))
    }

    private func receive(_ node: DownloadNode, at url: URL,
                         completed: inout UInt64, total: UInt64,
                         progress: @escaping @Sendable (TransferUpdate) -> Void) throws {
        try checkCancelled()
        if let children = node.children {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            for child in children {
                let destination = try FileSafety.destination(directory: url, name: child.item.name)
                try receive(child, at: destination, completed: &completed, total: total, progress: progress)
            }
            return
        }
        let context = ProgressContext(base: completed, total: total, callback: progress)
        let pointer = Unmanaged.passUnretained(context).toOpaque()
        var error: UnsafeMutablePointer<CChar>?
        let result = withExtendedLifetime(context) {
            amtp_download(session, node.item.id, url.path, cancellation.pointer, progressCallback, pointer, &error)
        }
        try check(result, error: error)
        completed = try safeAdd(completed, node.item.size)
        if let modified = node.item.modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        progress(TransferUpdate(completed: min(completed, total), total: total))
    }

    private func checkCancelled() throws {
        if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
    }

    private func check(_ result: Int32, error: UnsafeMutablePointer<CChar>?) throws {
        defer { if let error { amtp_free_error(error) } }
        guard result == 0 else {
            throw AndroidMTPError.message(error.map { String(cString: $0) } ?? "The MTP operation failed.")
        }
    }

    private func string(_ value: UnsafeMutablePointer<CChar>?) -> String {
        value.map { String(cString: $0) } ?? ""
    }
}
