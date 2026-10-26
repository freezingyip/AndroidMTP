import CAndroidMTP
import Darwin
import Foundation

private final class SystemTransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func reset() { lock.lock(); cancelled = false; lock.unlock() }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

private struct SystemUploadNode {
    let url: URL
    let name: String
    let size: UInt64
    let modified: Date?
    let children: [SystemUploadNode]?
}

private struct SystemDownloadNode {
    let item: RemoteItem
    let children: [SystemDownloadNode]?
}

private final class SystemTransferProgress {
    let total: UInt64
    private(set) var completed: UInt64 = 0
    private var lastEmission: UInt64 = 0
    private let callback: @Sendable (TransferUpdate) -> Void
    init(total: UInt64, callback: @escaping @Sendable (TransferUpdate) -> Void) {
        self.total = total; self.callback = callback
        callback(TransferUpdate(completed: 0, total: total))
    }
    func advance(_ bytes: UInt64) {
        let (value, overflow) = completed.addingReportingOverflow(bytes)
        completed = overflow ? total : min(value, total)
        emit()
    }
    func emit(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || lastEmission == 0 || now - lastEmission >= 100_000_000 || completed == total else { return }
        lastEmission = now
        callback(TransferUpdate(completed: completed, total: total))
    }
}

/// Uses macOS's own camera service as the transport, so photo importers do not compete
/// with this app for an exclusive libusb interface claim. USB debugging is not used.
public actor SystemMTPService {
    private var link: SystemPTPLink?
    private var connected = false
    private var operations = Set<UInt16>()
    private var busy = false
    private nonisolated let cancellation = SystemTransferCancellation()
    private let chunkSize = 1_048_576
    private let standardTransferLimit: UInt64 = 64 * 1_048_576

    public init() {}

    public nonisolated func cancelTransfers() { cancellation.cancel() }

    public func scan() async throws -> [DeviceInfo] {
        try beginOperation()
        defer { busy = false }
        return try await getLink().scan()
    }

    public func connect(_ device: DeviceInfo) async throws -> [StorageInfo] {
        try beginOperation()
        defer { busy = false }
        let transport = await getLink()
        if connected { await transport.disconnect() }
        connected = false
        operations.removeAll()
        try await transport.connect(device)
        connected = true
        do {
            let info = try await request(0x1001, parameters: [])
            operations = try PTPCodec.deviceOperations(info.data)
            let ids = try PTPCodec.uint32Array(try await request(0x1004, parameters: []).data)
            var storages: [StorageInfo] = []
            for id in ids {
                let data = try await request(0x1005, parameters: [id]).data
                storages.append(try PTPCodec.storageInfo(id: id, data: data))
            }
            guard !storages.isEmpty else {
                throw AndroidMTPError.message("The phone has not exposed any storage. Unlock it and choose File transfer.")
            }
            return storages
        } catch {
            connected = false
            operations.removeAll()
            await transport.disconnect()
            throw error
        }
    }

    public func disconnect() async {
        // Transactions are asynchronous and the actor can be re-entered. Wait until the
        // current public operation observes cancellation before closing its session.
        if busy { cancellation.cancel() }
        while busy {
            try? await Task.sleep(nanoseconds: 20_000_000)
            await Task.yield()
        }
        busy = true
        defer { busy = false }
        connected = false
        operations.removeAll()
        if let link { await link.disconnect() }
    }

    public func thumbnail(_ item: RemoteItem) async throws -> Data? {
        try beginOperation()
        defer { busy = false }
        try requireConnection()
        try checkCancelled()
        guard !item.isDirectory, operations.contains(0x100A) else { return nil }
        let result = try await getLink().transact(code: 0x100A, parameters: [item.id], data: nil)
        try checkCancelled()
        // AOSP returns GeneralError when its database has no thumbnail.
        if [UInt16(0x2002), 0x2005, 0x2010].contains(result.code) { return nil }
        guard result.code == 0x2001 else {
            throw AndroidMTPError.message("Could not read the photo preview (MTP \(String(format: "0x%04X", result.code))).")
        }
        guard !result.data.isEmpty, result.data.count <= 2 * 1024 * 1024 else { return nil }
        return result.data
    }

    public func list(storageID: UInt32, parentID: UInt32) async throws -> [RemoteItem] {
        try beginOperation()
        defer { busy = false }
        return try await readItems(storageID: storageID, parentID: parentID)
    }

    public func createFolder(name: String, storageID: UInt32, parentID: UInt32) async throws {
        try beginOperation()
        defer { busy = false }
        _ = try await makeFolder(name: name, storageID: storageID, parentID: parentID)
    }

    public func rename(_ item: RemoteItem, to name: String) async throws {
        try beginOperation()
        defer { busy = false }
        try FileSafety.validateName(name)
        let current = try await readItem(item.id, storageID: item.storageID)
        if current.name == name { return }
        try await requireUnusedName(name, storageID: current.storageID, parentID: current.parentID, excluding: current.id)
        _ = try await request(0x9804, parameters: [item.id, 0xDC07], data: PTPCodec.encodedString(name))
    }

    public func delete(_ item: RemoteItem) async throws {
        try beginOperation()
        defer { busy = false }
        try validateObjectID(item.id)
        // Never let a stale UI type turn a file deletion into a recursive folder deletion.
        let current = try await readItem(item.id, storageID: item.storageID)
        if current.isDirectory {
            let ids = try await childIDs(storageID: current.storageID, parentID: current.id)
            guard ids.isEmpty else {
                throw AndroidMTPError.message("This folder is not empty. Delete its contents separately before deleting the folder.")
            }
        }
        _ = try await request(0x100B, parameters: [item.id, 0])
    }

    public func upload(localURL: URL, storageID: UInt32, parentID: UInt32,
                       progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        try beginOperation()
        defer { busy = false }
        try requireConnection()
        let node = try prepareUpload(localURL, depth: 0)
        try verifyUploadSupport(node)
        try await requireUnusedName(node.name, storageID: storageID, parentID: parentID)
        let reporter = SystemTransferProgress(total: try uploadSize(node), callback: progress)
        try await send(node, storageID: storageID, parentID: parentID, reporter: reporter)
        try checkCancelled()
        reporter.emit(force: true)
    }

    public func download(_ item: RemoteItem, to localURL: URL,
                         progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        try beginOperation()
        defer { busy = false }
        try requireConnection()
        try FileSafety.validateName(item.name)
        guard localURL.isFileURL else { throw AndroidMTPError.message("Choose a local destination.") }
        let destination = try FileSafety.destination(directory: localURL.deletingLastPathComponent(), name: localURL.lastPathComponent)
        var seen = Set<UInt32>()
        let node = try await prepareDownload(item, seen: &seen, depth: 0)
        try verifyDownloadSupport(node)
        let reporter = SystemTransferProgress(total: try downloadSize(node), callback: progress)
        let staging = try FileSafety.destination(directory: destination.deletingLastPathComponent(), name: ".AndroidMTP-\(UUID().uuidString).partial")
        try makePrivateDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let payload = staging.appendingPathComponent("payload")
        try await receive(node, at: payload, reporter: reporter)
        try checkCancelled()
        var nativeError: UnsafeMutablePointer<CChar>?
        let status = amtp_move_no_replace(payload.path, destination.path, &nativeError)
        defer { if let nativeError { amtp_free_error(nativeError) } }
        guard status == 0 else {
            throw AndroidMTPError.message(nativeError.map { String(cString: $0) } ?? "Could not finish the download without replacing an existing item.")
        }
        reporter.emit(force: true)
    }

    private func beginOperation() throws {
        guard !busy else { throw AndroidMTPError.message("Wait for the current device operation to finish.") }
        busy = true
        cancellation.reset()
    }

    private func getLink() async -> SystemPTPLink {
        if let link { return link }
        let created = await SystemPTPLink()
        link = created
        return created
    }

    private func requireConnection() throws {
        guard connected else { throw AndroidMTPError.message("Connect an Android device first.") }
    }

    private func checkCancelled() throws {
        if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
    }

    private func validateObjectID(_ id: UInt32) throws {
        guard id != 0, id != UInt32.max else {
            throw AndroidMTPError.message("A storage root cannot be modified as a file.")
        }
    }

    private func request(_ code: UInt16, parameters: [UInt32], data: Data? = nil,
                         allowCancelled: Bool = false) async throws -> PTPResult {
        try requireConnection()
        if !allowCancelled { try checkCancelled() }
        guard operations.isEmpty || operations.contains(code) else {
            throw AndroidMTPError.message("This phone does not support the requested file operation (MTP \(String(format: "0x%04X", code))).")
        }
        let result = try await getLink().transact(code: code, parameters: parameters, data: data)
        guard result.code == 0x2001 else {
            let explanation: String
            switch result.code {
            case 0x2009: explanation = "The item is no longer available. Refresh the folder and try again."
            case 0x200F: explanation = "Android denied access. Unlock the phone and allow file access."
            case 0x2019: explanation = "The phone is busy. Wait for its current operation to finish and try again."
            case 0x200C: explanation = "The phone does not have enough free space."
            case 0x200D: explanation = "This item is protected against changes."
            case 0x200E: explanation = "The destination storage is read-only."
            case 0x2005: explanation = "This phone does not support the requested operation."
            default: explanation = "Android could not complete the file operation."
            }
            throw AndroidMTPError.message("\(explanation) (MTP \(String(format: "0x%04X", result.code)))")
        }
        return result
    }

    private func childIDs(storageID: UInt32, parentID: UInt32) async throws -> [UInt32] {
        let root = parentID == 0 ? UInt32.max : parentID
        let result = try await request(0x1007, parameters: [storageID, 0, root])
        return try PTPCodec.uint32Array(result.data)
    }

    private func readItem(_ id: UInt32, storageID: UInt32) async throws -> RemoteItem {
        try validateObjectID(id)
        let data = try await request(0x1008, parameters: [id]).data
        let item = try PTPCodec.objectInfo(handle: id, data: data, fallbackStorageID: storageID)
        guard !item.isDirectory, item.size >= UInt64(UInt32.max), operations.contains(0x9803) else { return item }
        let sizeData = try await request(0x9803, parameters: [id, 0xDC04]).data
        let size = try PTPCodec.uint64(sizeData)
        return RemoteItem(id: item.id, parentID: item.parentID, storageID: item.storageID,
                          name: item.name, size: size, modified: item.modified, isDirectory: false)
    }

    private func readItems(storageID: UInt32, parentID: UInt32) async throws -> [RemoteItem] {
        let ids = try await childIDs(storageID: storageID, parentID: parentID)
        var items: [RemoteItem] = []
        for id in ids { items.append(try await readItem(id, storageID: storageID)) }
        return items.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func requireUnusedName(_ name: String, storageID: UInt32, parentID: UInt32,
                                   excluding: UInt32? = nil) async throws {
        try FileSafety.validateName(name)
        let key = FileSafety.collisionKey(name)
        let items = try await readItems(storageID: storageID, parentID: parentID)
        guard !items.contains(where: { $0.id != excluding && FileSafety.collisionKey($0.name) == key }) else {
            throw AndroidMTPError.message("“\(name)” already exists on the phone. Rename it or choose another folder.")
        }
    }

    private func makeFolder(name: String, storageID: UInt32, parentID: UInt32) async throws -> UInt32 {
        try await requireUnusedName(name, storageID: storageID, parentID: parentID)
        // Android completes association creation during SendObjectInfo; no SendObject follows.
        return try await sendObjectInfo(name: name, storageID: storageID, parentID: parentID,
                                        size: 0, isDirectory: true, modified: nil)
    }

    private func sendObjectInfo(name: String, storageID: UInt32, parentID: UInt32,
                                size: UInt64, isDirectory: Bool, modified: Date?) async throws -> UInt32 {
        try FileSafety.validateName(name)
        let parent = parentID == 0 ? UInt32.max : parentID
        let dataset = try PTPCodec.objectInfoDataset(name: name, storageID: storageID, parentID: parent,
                                                    size: size, isDirectory: isDirectory, modified: modified)
        let result = try await request(0x100C, parameters: [storageID, parent], data: dataset)
        guard result.parameters.count >= 3 else {
            throw AndroidMTPError.message("The phone did not return the new item's handle.")
        }
        let id = result.parameters[2]
        try validateObjectID(id)
        return id
    }

    private var supportsChunkedUpload: Bool {
        [UInt16(0x95C2), 0x95C4, 0x95C5].allSatisfy { operations.contains($0) }
    }

    private func verifyUploadSupport(_ node: SystemUploadNode) throws {
        if let children = node.children { for child in children { try verifyUploadSupport(child) }; return }
        if node.size == 0, (!supportsChunkedUpload || !operations.contains(0x95C3)) {
            throw AndroidMTPError.message("This phone cannot create empty files through the macOS connection. Use the direct MTP connection for empty files.")
        }
        guard supportsChunkedUpload || node.size <= standardTransferLimit else {
            throw AndroidMTPError.message("This phone does not support chunked uploads through macOS. Files above 64 MB require the direct MTP connection.")
        }
    }

    private func verifyDownloadSupport(_ node: SystemDownloadNode) throws {
        if let children = node.children { for child in children { try verifyDownloadSupport(child) }; return }
        if node.item.size >= UInt64(UInt32.max), !operations.contains(0x9803) {
            throw AndroidMTPError.message("This phone did not expose the full size of this large file. Use the direct MTP connection for this file.")
        }
        if node.item.size > UInt64(UInt32.max), !operations.contains(0x95C1) {
            throw AndroidMTPError.message("This phone does not support 64-bit partial downloads through macOS. Use the direct MTP connection for this large file.")
        }
        if !operations.contains(0x101B), !operations.contains(0x95C1), node.item.size > standardTransferLimit {
            throw AndroidMTPError.message("This phone does not support chunked downloads through macOS. Files above 64 MB require the direct MTP connection.")
        }
    }

    private func prepareUpload(_ url: URL, depth: Int) throws -> SystemUploadNode {
        try checkCancelled()
        guard url.isFileURL, depth < 256 else {
            throw AndroidMTPError.message("The upload contains an invalid path or too many nested folders.")
        }
        let name = url.lastPathComponent
        try FileSafety.validateName(name)
        let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        guard info.isSymbolicLink != true else { throw AndroidMTPError.message("Symbolic links are not uploaded: “\(name)”.") }
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
            return SystemUploadNode(url: url, name: name, size: 0, modified: info.contentModificationDate, children: nodes)
        }
        guard info.isRegularFile == true, let size = info.fileSize, size >= 0 else {
            throw AndroidMTPError.message("“\(name)” is not a readable regular file.")
        }
        return SystemUploadNode(url: url, name: name, size: UInt64(size), modified: info.contentModificationDate, children: nil)
    }

    private func prepareDownload(_ item: RemoteItem, seen: inout Set<UInt32>, depth: Int) async throws -> SystemDownloadNode {
        try checkCancelled()
        guard depth < 256, seen.insert(item.id).inserted else {
            throw AndroidMTPError.message("The phone returned a repeated item or an excessively nested folder.")
        }
        let current = try await readItem(item.id, storageID: item.storageID)
        try FileSafety.validateName(current.name)
        guard current.isDirectory else { return SystemDownloadNode(item: current, children: nil) }
        let items = try await readItems(storageID: current.storageID, parentID: current.id)
        var names = Set<String>()
        var children: [SystemDownloadNode] = []
        for child in items {
            guard names.insert(FileSafety.collisionKey(child.name)).inserted else {
                throw AndroidMTPError.message("This folder contains names that would collide on your Mac: “\(child.name)”.")
            }
            children.append(try await prepareDownload(child, seen: &seen, depth: depth + 1))
        }
        return SystemDownloadNode(item: current, children: children)
    }

    private func uploadSize(_ node: SystemUploadNode) throws -> UInt64 {
        guard let children = node.children else { return node.size }
        return try children.reduce(0) { try safeAdd($0, uploadSize($1)) }
    }

    private func downloadSize(_ node: SystemDownloadNode) throws -> UInt64 {
        guard let children = node.children else { return node.item.size }
        return try children.reduce(0) { try safeAdd($0, downloadSize($1)) }
    }

    private func safeAdd(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw AndroidMTPError.message("The total transfer size is too large.") }
        return value
    }

    private func send(_ node: SystemUploadNode, storageID: UInt32, parentID: UInt32,
                      reporter: SystemTransferProgress) async throws {
        try checkCancelled()
        if let children = node.children {
            let id = try await makeFolder(name: node.name, storageID: storageID, parentID: parentID)
            for child in children { try await send(child, storageID: storageID, parentID: id, reporter: reporter) }
            return
        }
        try await requireUnusedName(node.name, storageID: storageID, parentID: parentID)
        let file = try openUploadFile(node)
        defer { try? file.close() }
        if !supportsChunkedUpload {
            // Bounded compatibility fallback. Never materialize an arbitrary-size file in Data.
            guard node.size <= standardTransferLimit else { throw AndroidMTPError.message("This file requires chunked upload support.") }
            var payload = Data()
            while UInt64(payload.count) < node.size {
                try checkCancelled()
                let remaining = node.size - UInt64(payload.count)
                let chunk = try file.read(upToCount: min(chunkSize, Int(remaining))) ?? Data()
                guard !chunk.isEmpty else { throw AndroidMTPError.message("The source file changed or became unreadable during upload.") }
                payload.append(chunk)
            }
            try verifyUploadFile(file, expectedSize: node.size)
            _ = try await sendObjectInfo(name: node.name, storageID: storageID, parentID: parentID,
                                         size: node.size, isDirectory: false, modified: node.modified)
            _ = try await request(0x100D, parameters: [], data: payload)
            reporter.advance(node.size)
            return
        }
        // ImageCaptureCore can omit a data phase for empty outgoing Data. Create a
        // one-byte placeholder, then overwrite or truncate it using Android edits.
        let id = try await sendObjectInfo(name: node.name, storageID: storageID, parentID: parentID,
                                          size: 1, isDirectory: false, modified: node.modified)
        _ = try await request(0x100D, parameters: [], data: Data([0]))
        _ = try await request(0x95C4, parameters: [id])
        do {
            if node.size == 0 {
                _ = try await request(0x95C3, parameters: [id, 0, 0])
            }
            var offset: UInt64 = 0
            while offset < node.size {
                try checkCancelled()
                let remaining = node.size - offset
                let chunk = try file.read(upToCount: min(chunkSize, Int(min(remaining, UInt64(chunkSize))))) ?? Data()
                guard !chunk.isEmpty else { throw AndroidMTPError.message("The source file changed or became unreadable during upload.") }
                _ = try await request(0x95C2, parameters: [id, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), UInt32(chunk.count)], data: chunk)
                offset += UInt64(chunk.count)
                reporter.advance(UInt64(chunk.count))
            }
            try verifyUploadFile(file, expectedSize: node.size)
            try checkCancelled()
            _ = try await request(0x95C5, parameters: [id], allowCancelled: true)
        } catch {
            // End the edit even after cancellation. It only commits bytes already sent to this
            // newly created object; it never deletes or replaces another remote object.
            _ = try? await request(0x95C5, parameters: [id], allowCancelled: true)
            throw error
        }
        let actual = try await readItem(id, storageID: storageID)
        guard actual.size == node.size else {
            throw AndroidMTPError.message("Android reported an incomplete upload. A partial upload may remain on the phone.")
        }
    }

    private func openUploadFile(_ node: SystemUploadNode) throws -> FileHandle {
        let fd = node.url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
        guard fd >= 0 else { throw systemError("Could not open the upload file") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do { try verifyUploadFile(file, expectedSize: node.size) }
        catch { try? file.close(); throw error }
        return file
    }

    private func verifyUploadFile(_ file: FileHandle, expectedSize: UInt64) throws {
        var info = stat()
        guard fstat(file.fileDescriptor, &info) == 0 else { throw systemError("Could not inspect the upload file") }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0, UInt64(info.st_size) == expectedSize else {
            throw AndroidMTPError.message("The source file changed or is not a regular file. Try the upload again.")
        }
    }

    private func receive(_ node: SystemDownloadNode, at url: URL, reporter: SystemTransferProgress) async throws {
        try checkCancelled()
        if let children = node.children {
            try makePrivateDirectory(url)
            for child in children {
                let destination = try FileSafety.destination(directory: url, name: child.item.name)
                try await receive(child, at: destination, reporter: reporter)
            }
            return
        }
        let fd = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw systemError("Could not create the download file") }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            if !operations.contains(0x101B), !operations.contains(0x95C1) {
                guard node.item.size <= standardTransferLimit else { throw AndroidMTPError.message("This file requires chunked download support.") }
                let data = try await request(0x1009, parameters: [node.item.id]).data
                guard UInt64(data.count) == node.item.size else { throw AndroidMTPError.message("Android returned an incomplete download.") }
                try file.write(contentsOf: data)
                reporter.advance(UInt64(data.count))
            } else {
                var offset: UInt64 = 0
                while offset < node.item.size {
                    try checkCancelled()
                    let length = UInt32(min(UInt64(chunkSize), node.item.size - offset))
                    let result: PTPResult
                    if operations.contains(0x95C1) {
                        result = try await request(0x95C1, parameters: [node.item.id, UInt32(truncatingIfNeeded: offset), UInt32(offset >> 32), length])
                    } else {
                        guard offset <= UInt64(UInt32.max) else { throw AndroidMTPError.message("This phone cannot download beyond the 4 GB offset.") }
                        result = try await request(0x101B, parameters: [node.item.id, UInt32(offset), length])
                    }
                    guard !result.data.isEmpty, result.data.count <= Int(length) else {
                        throw AndroidMTPError.message("Android returned an incomplete or invalid download chunk.")
                    }
                    if let returned = result.parameters.first, returned != UInt32(result.data.count) {
                        throw AndroidMTPError.message("Android's download byte count did not match the received data.")
                    }
                    try file.write(contentsOf: result.data)
                    offset += UInt64(result.data.count)
                    reporter.advance(UInt64(result.data.count))
                }
            }
            try file.synchronize()
            try file.close()
        } catch { try? file.close(); throw error }
        let current = try await readItem(node.item.id, storageID: node.item.storageID)
        guard current.size == node.item.size else {
            throw AndroidMTPError.message("The file changed on Android during the download. Please try again.")
        }
        if let modified = node.item.modified {
            try? FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func makePrivateDirectory(_ url: URL) throws {
        guard url.path.withCString({ Darwin.mkdir($0, 0o700) }) == 0 else {
            throw systemError("Could not create a private download folder")
        }
    }

    private func systemError(_ description: String) -> AndroidMTPError {
        .message("\(description): \(String(cString: strerror(errno))).")
    }
}
