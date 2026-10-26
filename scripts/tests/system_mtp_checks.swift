// Compile with SystemMTPService + codec + models + MTPService, WITHOUT SystemPTPLink.
// This scripted transport never imports ImageCaptureCore or accesses a device.
import Foundation

@MainActor
final class SystemPTPLink {
    struct Object {
        var item: RemoteItem
        var bytes: Data
    }
    static let fullOperations: Set<UInt16> = [0x1001,0x1004,0x1005,0x1007,0x1008,0x1009,0x100A,0x100B,0x100C,0x100D,0x101B,0x9803,0x9804,0x95C1,0x95C2,0x95C3,0x95C4,0x95C5]
    static var nextOperations = fullOperations
    static var latest: SystemPTPLink?
    var thumbnailCode: UInt16 = 0x2001
    var thumbnailBytes = Data([1, 2, 3])
    var supported: Set<UInt16>
    var objects: [UInt32: Object] = [:]
    var nextID: UInt32 = 100
    var pending: UInt32?
    var edits = Set<UInt32>()
    var sendObjectPayloadSizes: [Int] = []
    var truncateCalls = 0
    var endEditCalls = 0
    var largestChunk = 0
    var onChunk: (() -> Void)?
    var onTruncate: (() -> Void)?
    var blockHandles = false
    var handlesContinuation: CheckedContinuation<Void, Never>?
    init() { supported = Self.nextOperations; Self.latest = self }
    func scan() async throws -> [DeviceInfo] { [DeviceInfo(id: "system:test", name: "Test phone", bus: 1, address: 1)] }
    func connect(_ device: DeviceInfo) async throws {}
    func disconnect() async {}

    func transact(code: UInt16, parameters: [UInt32], data: Data?) async throws -> PTPResult {
        func ok(_ data: Data = Data(), _ parameters: [UInt32] = []) -> PTPResult { PTPResult(data: data, code: 0x2001, parameters: parameters) }
        switch code {
        case 0x1001:
            var result = Data()
            result.put(UInt16(100)); result.put(UInt32(6)); result.put(UInt16(100))
            result.append(0); result.put(UInt16(0)); result.put(UInt32(supported.count))
            supported.sorted().forEach { result.put($0) }
            for _ in 0..<4 { result.put(UInt32(0)) }
            return ok(result)
        case 0x1004:
            var result = Data(); result.put(UInt32(1)); result.put(UInt32(1)); return ok(result)
        case 0x1005:
            var result = Data(); result.put(UInt16(3)); result.put(UInt16(2)); result.put(UInt16(0))
            result.put(UInt64(1 << 40)); result.put(UInt64(1 << 39)); result.put(UInt32.max)
            result.append(try PTPCodec.encodedString("Test storage")); result.append(0); return ok(result)
        case 0x1007:
            if blockHandles {
                blockHandles = false
                await withCheckedContinuation { handlesContinuation = $0 }
            }
            let ids = objects.values.filter { $0.item.parentID == parameters[2] }.map { $0.item.id }.sorted()
            var result = Data(); result.put(UInt32(ids.count)); ids.forEach { result.put($0) }; return ok(result)
        case 0x1008:
            guard let object = objects[parameters[0]] else { return PTPResult(data: Data(), code: 0x2009, parameters: []) }
            let item = object.item
            return ok(try PTPCodec.objectInfoDataset(name: item.name, storageID: item.storageID, parentID: item.parentID,
                size: min(item.size, UInt64(UInt32.max)), isDirectory: item.isDirectory, modified: nil))
        case 0x9803:
            var result = Data(); result.put(objects[parameters[0]]!.item.size); return ok(result)
        case 0x100C:
            guard parameters[1] == UInt32.max || objects[parameters[1]]?.item.isDirectory == true else {
                throw AndroidMTPError.message("Test: invalid parent handle")
            }
            let id = nextID; nextID += 1
            let item = try PTPCodec.objectInfo(handle: id, data: data!, fallbackStorageID: parameters[0])
            objects[id] = Object(item: item, bytes: Data())
            if !item.isDirectory { pending = id }
            return ok(Data(), [parameters[0], parameters[1], id])
        case 0x100D:
            guard let id = pending, let data, !data.isEmpty else {
                throw AndroidMTPError.message("Test: ImageCaptureCore cannot send an empty data phase")
            }
            guard objects[id]!.item.size == UInt64(data.count) else {
                throw AndroidMTPError.message("Test: SendObject payload differs from declared size")
            }
            sendObjectPayloadSizes.append(data.count)
            setBytes(id, data); pending = nil; return ok()
        case 0x95C4:
            edits.insert(parameters[0]); return ok()
        case 0x95C5:
            endEditCalls += 1; edits.remove(parameters[0]); return ok()
        case 0x95C3:
            let id = parameters[0]
            guard edits.contains(id), parameters.count == 3 else {
                throw AndroidMTPError.message("Test: truncate needs an active edit")
            }
            let size = UInt64(parameters[1]) | (UInt64(parameters[2]) << 32)
            guard size <= UInt64(objects[id]!.bytes.count) else {
                throw AndroidMTPError.message("Test: unexpected growing truncate")
            }
            setBytes(id, Data(objects[id]!.bytes.prefix(Int(size))))
            truncateCalls += 1
            onTruncate?()
            return ok()
        case 0x95C2:
            let id = parameters[0]
            guard edits.contains(id), let data else { throw AndroidMTPError.message("Test: missing edit/data") }
            let offset = UInt64(parameters[1]) | (UInt64(parameters[2]) << 32)
            guard offset <= UInt64(objects[id]!.bytes.count), parameters[3] == UInt32(data.count) else {
                throw AndroidMTPError.message("Test: invalid partial upload range")
            }
            largestChunk = max(largestChunk, data.count)
            var bytes = objects[id]!.bytes
            let begin = Int(offset), end = min(bytes.count, Int(offset) + data.count)
            bytes.replaceSubrange(begin..<end, with: data)
            setBytes(id, bytes)
            onChunk?()
            return ok(Data(), [UInt32(data.count)])
        case 0x101B, 0x95C1:
            let offset = code == 0x95C1 ? UInt64(parameters[1]) | (UInt64(parameters[2]) << 32) : UInt64(parameters[1])
            let length = Int(parameters[code == 0x95C1 ? 3 : 2])
            let bytes = objects[parameters[0]]!.bytes
            let begin = Int(offset); let end = min(bytes.count, begin + length)
            let payload = bytes.subdata(in: begin..<end)
            largestChunk = max(largestChunk, payload.count)
            return ok(payload, [UInt32(payload.count)])
        case 0x100A: return PTPResult(data: thumbnailBytes, code: thumbnailCode, parameters: [])
        case 0x1009: return ok(objects[parameters[0]]!.bytes)
        case 0x9804:
            let id = parameters[0]; let old = objects[id]!
            let wrapped = try PTPCodec.objectInfoDataset(name: "unused", storageID: 1, parentID: old.item.parentID, size: old.item.size, isDirectory: old.item.isDirectory, modified: nil)
            // Dataset string is independently decoded through ObjectInfo, replacing its filename.
            var replacement = wrapped.prefix(52); replacement.append(data!); replacement.append(contentsOf: [0,0,0])
            let renamed = try PTPCodec.objectInfo(handle: id, data: replacement, fallbackStorageID: 1)
            objects[id] = Object(item: renamed, bytes: old.bytes); return ok()
        case 0x100B:
            objects.removeValue(forKey: parameters[0]); return ok()
        default: throw AndroidMTPError.message("Unexpected test operation \(code)")
        }
    }

    private func setBytes(_ id: UInt32, _ bytes: Data) {
        let old = objects[id]!.item
        let item = RemoteItem(id: old.id, parentID: old.parentID, storageID: old.storageID, name: old.name,
                              size: UInt64(bytes.count), modified: nil, isDirectory: old.isDirectory)
        objects[id] = Object(item: item, bytes: bytes)
    }
}

extension Data {
    fileprivate mutating func put<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}

@main
struct SystemServiceChecks {
    enum Failure: Error { case check(String) }
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure.check(message) }
    }
    static func rejects(_ name: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw Failure.check("Expected rejection: \(name)")
    }
    @MainActor
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AndroidMTP-system-tests-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let input = temporary.appendingPathComponent("RoundTrip")
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
        let payload = Data((0..<2_500_123).map { UInt8(truncatingIfNeeded: $0) })
        try payload.write(to: input.appendingPathComponent("照片.bin"))
        try Data().write(to: input.appendingPathComponent("empty.txt"))
        try FileManager.default.createDirectory(at: input.appendingPathComponent("Empty folder"), withIntermediateDirectories: false)
        let service = SystemMTPService()
        let devices = try await service.scan()
        _ = try await service.connect(devices[0])
        let fake = SystemPTPLink.latest!
        let testPhoto = RemoteItem(id: 42, parentID: 0, storageID: 1, name: "large.jpg", size: 40_000_000, modified: nil, isDirectory: false)
        let thumb = try await service.thumbnail(testPhoto)
        try expect(thumb == fake.thumbnailBytes, "Thumbnail request did not return device thumbnail data")
        fake.thumbnailCode = 0x2002
        let absent = try await service.thumbnail(testPhoto)
        try expect(absent == nil, "AOSP missing-thumbnail response must not trigger an original read")
        fake.thumbnailCode = 0x2001
        fake.thumbnailBytes = Data(repeating: 0, count: 2 * 1024 * 1024 + 1)
        let oversized = try await service.thumbnail(testPhoto)
        try expect(oversized == nil, "Oversized thumbnail must be rejected")
        try await service.upload(localURL: input, storageID: 1, parentID: UInt32.max, progress: { _ in })
        let root = try await service.list(storageID: 1, parentID: UInt32.max)
        let folder = root.first { $0.name == "RoundTrip" }!
        try expect(fake.largestChunk <= 1_048_576, "Upload materialized an oversized chunk")
        try expect(fake.edits.isEmpty, "Successful upload left an edit open")
        try expect(fake.sendObjectPayloadSizes == [1,1], "Chunked uploads must initialize with nonempty one-byte placeholders")
        try expect(fake.truncateCalls == 1, "The empty file must truncate its placeholder within an edit")
        let output = temporary.appendingPathComponent("Downloaded")
        try await service.download(folder, to: output, progress: { _ in })
        try expect(try Data(contentsOf: output.appendingPathComponent("照片.bin")) == payload, "Recursive transfer round trip changed bytes")
        try expect(try Data(contentsOf: output.appendingPathComponent("empty.txt")).isEmpty, "Empty file was not transferred")
        try expect(FileManager.default.fileExists(atPath: output.appendingPathComponent("Empty folder").path), "Empty folder was not transferred")
        try await rejects("duplicate remote folder") { try await service.upload(localURL: input, storageID: 1, parentID: UInt32.max, progress: { _ in }) }
        try await rejects("existing local destination") { try await service.download(folder, to: output, progress: { _ in }) }
        try expect(try Data(contentsOf: output.appendingPathComponent("照片.bin")) == payload, "Collision handling changed existing bytes")
        try await rejects("nonempty folder delete") { try await service.delete(folder) }
        let children = try await service.list(storageID: 1, parentID: folder.id)
        let emptyFolder = children.first { $0.isDirectory }!
        try await service.delete(emptyFolder)
        let emptyFile = children.first { $0.name == "empty.txt" }!
        try await service.rename(emptyFile, to: "renamed.txt")
        try expect(fake.objects[emptyFile.id]?.item.name == "renamed.txt", "Rename did not reach the protocol")

        fake.blockHandles = true
        let waiting = Task { try await service.list(storageID: 1, parentID: UInt32.max) }
        while fake.handlesContinuation == nil { await Task.yield() }
        try await rejects("reentrant public operation") { _ = try await service.list(storageID: 1, parentID: UInt32.max) }
        fake.handlesContinuation?.resume(); fake.handlesContinuation = nil
        _ = try await waiting.value

        let cancelled = temporary.appendingPathComponent("Cancelled.bin")
        try payload.write(to: cancelled)
        fake.onChunk = { service.cancelTransfers() }
        try await rejects("cancelled upload") { try await service.upload(localURL: cancelled, storageID: 1, parentID: UInt32.max, progress: { _ in }) }
        fake.onChunk = nil
        let partial = fake.objects.values.first { $0.item.name == "Cancelled.bin" }!
        try expect(partial.bytes.count == 1_048_576 && fake.edits.isEmpty, "Cancellation should stop at one bounded chunk and close its edit")

        let cancelledEmpty = temporary.appendingPathComponent("Cancelled-empty.txt")
        try Data().write(to: cancelledEmpty)
        let endedBeforeTruncate = fake.endEditCalls
        fake.onTruncate = { service.cancelTransfers() }
        try await rejects("cancelled empty-file truncation") {
            try await service.upload(localURL: cancelledEmpty, storageID: 1, parentID: UInt32.max, progress: { _ in })
        }
        fake.onTruncate = nil
        let emptyPartial = fake.objects.values.first { $0.item.name == "Cancelled-empty.txt" }!
        try expect(emptyPartial.bytes.isEmpty && fake.edits.isEmpty && fake.endEditCalls == endedBeforeTruncate + 1,
                   "Cancellation after truncation must still end the edit exactly once")

        SystemPTPLink.nextOperations = SystemPTPLink.fullOperations.subtracting([0x95C2,0x95C4,0x95C5])
        let compatibility = SystemMTPService()
        _ = try await compatibility.scan(); _ = try await compatibility.connect(devices[0])
        let sparse = temporary.appendingPathComponent("Large-sparse.bin")
        FileManager.default.createFile(atPath: sparse.path, contents: Data())
        let file = try FileHandle(forWritingTo: sparse)
        try file.truncate(atOffset: 65 * 1_048_576); try file.close()
        try await rejects("large upload without edit support") { try await compatibility.upload(localURL: sparse, storageID: 1, parentID: UInt32.max, progress: { _ in }) }
        try expect(SystemPTPLink.latest!.objects.isEmpty, "Unsupported large upload created a remote placeholder")
        try await rejects("empty upload without edit support") {
            try await compatibility.upload(localURL: cancelledEmpty, storageID: 1, parentID: UInt32.max, progress: { _ in })
        }
        try expect(SystemPTPLink.latest!.objects.isEmpty, "Unsupported empty upload created a remote placeholder")
        let small = temporary.appendingPathComponent("Small.txt")
        try Data("ordinary".utf8).write(to: small)
        try await compatibility.upload(localURL: small, storageID: 1, parentID: UInt32.max, progress: { _ in })
        try expect(SystemPTPLink.latest!.objects.values.first?.bytes == Data("ordinary".utf8), "Small standard fallback changed bytes")

        SystemPTPLink.nextOperations = SystemPTPLink.fullOperations.subtracting([0x95C3])
        let noTruncate = SystemMTPService()
        _ = try await noTruncate.scan(); _ = try await noTruncate.connect(devices[0])
        try await rejects("empty upload without truncate support") {
            try await noTruncate.upload(localURL: cancelledEmpty, storageID: 1, parentID: UInt32.max, progress: { _ in })
        }
        try expect(SystemPTPLink.latest!.objects.isEmpty, "Missing truncate support must fail before creating a placeholder")
        await noTruncate.disconnect(); await compatibility.disconnect(); await service.disconnect()
        print("System MTP service checks passed: recursive bytes, Unicode, one-byte placeholders, empty-file truncation, safe collisions, deletion, rename, serialization, bounded chunks, cancellation/edit closure, and compatibility preflight.")
    }
}
