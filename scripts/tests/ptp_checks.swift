import Foundation

@main
struct PTPChecks {
    enum Failure: Error { case check(String) }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.check(message) }
    }

    static func rejects(_ name: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure.check("Malformed input accepted: \(name)")
    }

    static func hex(_ string: String) -> Data {
        let bytes = Array(string.filter { !$0.isWhitespace })
        precondition(bytes.count.isMultiple(of: 2))
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(bytes[$0...($0 + 1)]), radix: 16)!
        })
    }

    static func main() throws {
        let storageIDs = try PTPCodec.uint32Array(hex("0100000001000100"))
        try expect(storageIDs == [0x00010001], "StorageID little-endian/count parsing failed")
        let response = try PTPCodec.response(hex("0c0000000300012006000000"), data: Data([9, 8, 7]))
        try expect(response.code == 0x2001 && response.parameters.isEmpty && response.data == Data([9, 8, 7]),
                   "Real-shaped success response decoding failed")
        let withParameter = try PTPCodec.response(hex("1000000003000120060000007f000000"), data: Data())
        try expect(withParameter.parameters == [127], "Response parameters were not decoded")
        let command = try PTPCodec.command(code: 0x1004, parameters: [0x00010001])
        try expect(command == hex("10000000010004100100000001000100"), "Command framing failed")
        try rejects("six command parameters") { _ = try PTPCodec.command(code: 0x1004, parameters: [1,2,3,4,5,6]) }
        try rejects("wrong response type") { _ = try PTPCodec.response(hex("0c0000000200012006000000"), data: Data()) }
        try rejects("response length mismatch") { _ = try PTPCodec.response(hex("100000000300012006000000"), data: Data()) }
        try rejects("truncated response") { _ = try PTPCodec.response(hex("0c00000003000120"), data: Data()) }
        try rejects("nonparameter trailing byte") { _ = try PTPCodec.response(hex("0d000000030001200600000000"), data: Data()) }
        try rejects("huge array") { _ = try PTPCodec.uint32Array(hex("ffffffff")) }
        try rejects("truncated array") { _ = try PTPCodec.uint32Array(hex("0200000001000100")) }
        try rejects("trailing array bytes") { _ = try PTPCodec.uint32Array(hex("0000000001")) }

        let large = try PTPCodec.uint64(hex("8877665544332211"))
        try expect(large == 0x1122334455667788, "64-bit size property was truncated")
        try rejects("short uint64") { _ = try PTPCodec.uint64(hex("01000000")) }
        try rejects("oversized uint64") { _ = try PTPCodec.uint64(hex("010000000000000000")) }
        var storage = hex("030002000000 0000000000010000 0000000080000000 ffffffff")
        storage.append(try PTPCodec.encodedString("Internal storage"))
        storage.append(0)
        let info = try PTPCodec.storageInfo(id: 0x00010001, data: storage)
        try expect(info.name == "Internal storage" && info.capacity == 1 << 40 && info.freeSpace == 1 << 39,
                   "StorageInfo must preserve its 64-bit capacities")
        try rejects("truncated StorageInfo") { _ = try PTPCodec.storageInfo(id: 1, data: storage.prefix(20)) }

        let unicode = "照片📱.jpg"
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        let objectData = try PTPCodec.objectInfoDataset(name: unicode, storageID: 0x00010001,
            parentID: 42, size: UInt64(UInt32.max), isDirectory: false, modified: modified)
        let object = try PTPCodec.objectInfo(handle: 17, data: objectData, fallbackStorageID: 99)
        try expect(object.name == unicode && object.id == 17 && object.parentID == 42,
                   "ObjectInfo identity or Unicode round trip failed")
        try expect(object.storageID == 0x00010001 && object.size == UInt64(UInt32.max) && !object.isDirectory,
                   "ObjectInfo metadata round trip failed")
        try expect(object.modified == modified, "ObjectInfo modification time round trip failed")
        let folderData = try PTPCodec.objectInfoDataset(name: "Downloads", storageID: 0,
            parentID: UInt32.max, size: 0, isDirectory: true, modified: nil)
        let folder = try PTPCodec.objectInfo(handle: 18, data: folderData, fallbackStorageID: 99)
        try expect(folder.isDirectory && folder.parentID == UInt32.max && folder.storageID == 99,
                   "ObjectInfo folder/root/fallback handling failed")
        var truncatedString = objectData
        truncatedString[52] = 255
        try rejects("truncated UTF16 string") { _ = try PTPCodec.objectInfo(handle: 1, data: truncatedString, fallbackStorageID: 1) }
        try rejects("truncated ObjectInfo") { _ = try PTPCodec.objectInfo(handle: 1, data: objectData.prefix(51), fallbackStorageID: 1) }
        try rejects("oversized ObjectInfo file") {
            _ = try PTPCodec.objectInfoDataset(name: "large", storageID: 1, parentID: 0,
                size: UInt64(UInt32.max) + 1, isDirectory: false, modified: nil)
        }
        try rejects("invalid object name") {
            _ = try PTPCodec.objectInfoDataset(name: "../escape", storageID: 1, parentID: 0,
                size: 0, isDirectory: false, modified: nil)
        }
        let emoji = try PTPCodec.encodedString("📱")
        try expect(emoji == hex("033dd8f1dc0000"), "Non-BMP UTF16 encoding failed")
        let boundary = try PTPCodec.encodedString(String(repeating: "a", count: 254))
        try expect(boundary.first == 255 && boundary.count == 511, "Maximum PTP string count is wrong")
        try rejects("too-long UTF16 string") { _ = try PTPCodec.encodedString(String(repeating: "📱", count: 128)) }
        try rejects("embedded NUL") { _ = try PTPCodec.encodedString("hello\0world") }

        var device = hex("6400060000006400000000 0200000001100410 00000000000000000000000000000000")
        // Header: StandardVersion + vendor ID/version + empty vendor description + functional mode.
        let operations = try PTPCodec.deviceOperations(device)
        try expect(operations == [0x1001, 0x1004], "DeviceInfo operation parsing failed")
        device.removeLast()
        try rejects("truncated DeviceInfo arrays") { _ = try PTPCodec.deviceOperations(device) }
        print("PTP checks passed: command/response framing, malformed datasets, Unicode, object metadata, and 64-bit values.")
    }
}
