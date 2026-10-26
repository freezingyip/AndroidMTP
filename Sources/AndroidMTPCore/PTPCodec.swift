import Foundation

struct PTPResult: Sendable {
    let data: Data
    let code: UInt16
    let parameters: [UInt32]
}

/// Original little-endian PTP/MTP dataset codec. Layout references:
/// https://github.com/libmtp/libmtp/blob/master/src/ptp.h
/// https://github.com/libmtp/libmtp/blob/master/src/ptp-pack.c
enum PTPCodec {
    static func command(code: UInt16, parameters: [UInt32]) throws -> Data {
        guard parameters.count <= 5 else { throw malformed("A PTP command has at most five parameters.") }
        var writer = Writer()
        writer.u32(UInt32(12 + parameters.count * 4))
        writer.u16(1)
        writer.u16(code)
        // ImageCaptureCore assigns its own transaction identifier.
        writer.u32(1)
        parameters.forEach { writer.u32($0) }
        return writer.data
    }

    static func response(_ response: Data, data: Data) throws -> PTPResult {
        guard (12...32).contains(response.count), (response.count - 12).isMultiple(of: 4) else {
            throw malformed("Invalid PTP response length.")
        }
        var reader = Reader(response)
        let declared = try reader.u32()
        guard declared == UInt32(response.count), try reader.u16() == 3 else {
            throw malformed("Invalid PTP response container.")
        }
        let code = try reader.u16()
        _ = try reader.u32()
        var parameters = [UInt32]()
        while reader.remaining > 0 { parameters.append(try reader.u32()) }
        return PTPResult(data: data, code: code, parameters: parameters)
    }

    static func deviceOperations(_ data: Data) throws -> Set<UInt16> {
        var reader = Reader(data)
        _ = try reader.u16() // StandardVersion
        _ = try reader.u32() // VendorExtensionID
        _ = try reader.u16() // VendorExtensionVersion
        _ = try reader.string()
        _ = try reader.u16() // FunctionalMode
        let operations = try reader.u16Array()
        // The four remaining arrays are mandatory even if they are empty.
        for _ in 0..<4 { _ = try reader.u16Array() }
        // Manufacturer, model, version and serial are optional on some responders.
        for _ in 0..<4 where reader.remaining > 0 { _ = try reader.string() }
        return Set(operations)
    }

    static func uint32Array(_ data: Data) throws -> [UInt32] {
        var reader = Reader(data)
        let values = try reader.u32Array()
        guard reader.remaining == 0 else { throw malformed("Unexpected bytes after the PTP array.") }
        return values
    }

    static func uint64(_ data: Data) throws -> UInt64 {
        var reader = Reader(data)
        let value = try reader.u64()
        guard reader.remaining == 0 else { throw malformed("Invalid 64-bit MTP property length.") }
        return value
    }

    static func storageInfo(id: UInt32, data: Data) throws -> StorageInfo {
        var reader = Reader(data)
        _ = try reader.u16() // StorageType
        _ = try reader.u16() // FilesystemType
        _ = try reader.u16() // AccessCapability
        let capacity = try reader.u64()
        let available = try reader.u64()
        _ = try reader.u32() // FreeSpaceInImages
        let description = try reader.string()
        let volumeLabel = try reader.string()
        let name = !description.isEmpty ? description : (!volumeLabel.isEmpty ? volumeLabel : String(format: "Storage %08X", id))
        return StorageInfo(id: id, name: name, capacity: capacity, freeSpace: available)
    }

    static func objectInfo(handle: UInt32, data: Data, fallbackStorageID: UInt32) throws -> RemoteItem {
        var reader = Reader(data)
        let storage = try reader.u32()
        let format = try reader.u16()
        _ = try reader.u16() // ProtectionStatus
        let size = UInt64(try reader.u32())
        _ = try reader.u16() // ThumbFormat
        for _ in 0..<6 { _ = try reader.u32() } // Thumbnail and image dimensions
        let parent = try reader.u32()
        let association = try reader.u16()
        _ = try reader.u32() // AssociationDesc
        _ = try reader.u32() // SequenceNumber
        let name = try reader.string()
        _ = try reader.string() // CaptureDate
        let modification = try reader.string()
        if reader.remaining > 0 { _ = try reader.string() } // Keywords
        guard !name.isEmpty else { throw malformed("The device returned an unnamed object.") }
        return RemoteItem(
            id: handle, parentID: parent == 0 ? UInt32.max : parent,
            storageID: storage == 0 ? fallbackStorageID : storage, name: name, size: size,
            modified: parseDate(modification), isDirectory: format == 0x3001 || association == 1
        )
    }

    static func objectInfoDataset(name: String, storageID: UInt32, parentID: UInt32,
                                  size: UInt64, isDirectory: Bool, modified: Date?) throws -> Data {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw malformed("Choose a valid file or folder name.")
        }
        guard size <= UInt64(UInt32.max) else {
            throw malformed("This MTP upload method cannot represent files larger than 4 GB.")
        }
        var writer = Writer()
        writer.u32(storageID)
        writer.u16(isDirectory ? 0x3001 : 0x3000)
        writer.u16(0)
        writer.u32(isDirectory ? 0 : UInt32(size))
        writer.u16(0)
        for _ in 0..<6 { writer.u32(0) }
        writer.u32(parentID == UInt32.max ? 0 : parentID)
        writer.u16(isDirectory ? 1 : 0)
        writer.u32(0)
        writer.u32(0)
        writer.data.append(try encodedString(name))
        writer.data.append(try encodedString("")) // CaptureDate is unspecified.
        writer.data.append(try encodedString(modified.map(formatDate) ?? ""))
        writer.data.append(try encodedString(""))
        return writer.data
    }

    static func encodedString(_ string: String) throws -> Data {
        guard !string.contains("\0") else { throw malformed("MTP strings cannot contain a null character.") }
        let units = Array(string.utf16)
        guard units.count <= 254 else { throw malformed("The name is too long for this MTP device (254 UTF-16 units maximum).") }
        if units.isEmpty { return Data([0]) }
        var writer = Writer()
        writer.data.append(UInt8(units.count + 1))
        units.forEach { writer.u16($0) }
        writer.u16(0)
        return writer.data
    }

    private static func parseDate(_ string: String) -> Date? {
        guard !string.isEmpty, string.count <= 64 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.isLenient = false
        for format in ["yyyyMMdd'T'HHmmss.SSSZ", "yyyyMMdd'T'HHmmssZ", "yyyyMMdd'T'HHmmss.SSS", "yyyyMMdd'T'HHmmss"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    private static func malformed(_ message: String) -> AndroidMTPError {
        .message(message)
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset = 0
        var remaining: Int { bytes.count - offset }

        init(_ data: Data) { bytes = Array(data) }

        mutating func u8() throws -> UInt8 {
            guard remaining >= 1 else { throw malformed("The device returned a truncated MTP dataset.") }
            defer { offset += 1 }
            return bytes[offset]
        }

        mutating func u16() throws -> UInt16 {
            let a = UInt16(try u8())
            return a | (UInt16(try u8()) << 8)
        }

        mutating func u32() throws -> UInt32 {
            let a = UInt32(try u16())
            return a | (UInt32(try u16()) << 16)
        }

        mutating func u64() throws -> UInt64 {
            let a = UInt64(try u32())
            return a | (UInt64(try u32()) << 32)
        }

        mutating func count(width: Int) throws -> Int {
            let value = try u32()
            guard value <= 1_000_000, UInt64(value) <= UInt64(remaining / width) else {
                throw malformed("The device returned an invalid MTP array length.")
            }
            return Int(value)
        }

        mutating func u16Array() throws -> [UInt16] {
            let length = try count(width: 2)
            return try (0..<length).map { _ in try u16() }
        }

        mutating func u32Array() throws -> [UInt32] {
            let length = try count(width: 4)
            return try (0..<length).map { _ in try u32() }
        }

        mutating func string() throws -> String {
            let length = Int(try u8())
            if length == 0 { return "" }
            guard remaining >= length * 2 else { throw malformed("The device returned a truncated MTP string.") }
            var units = [UInt16]()
            for _ in 0..<length { units.append(try u16()) }
            guard units.last == 0 else { throw malformed("The device returned an unterminated MTP string.") }
            units.removeLast()
            guard !units.contains(0) else { throw malformed("The device returned an invalid MTP string.") }
            var encoded = Data()
            for unit in units { encoded.append(UInt8(truncatingIfNeeded: unit)); encoded.append(UInt8(unit >> 8)) }
            guard let decoded = String(data: encoded, encoding: .utf16LittleEndian) else {
                throw malformed("The device returned invalid UTF-16 text.")
            }
            return decoded
        }
    }

    private struct Writer {
        var data = Data()
        mutating func u16(_ value: UInt16) {
            data.append(UInt8(truncatingIfNeeded: value)); data.append(UInt8(value >> 8))
        }
        mutating func u32(_ value: UInt32) {
            u16(UInt16(truncatingIfNeeded: value)); u16(UInt16(value >> 16))
        }
    }
}
