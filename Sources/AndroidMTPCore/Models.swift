import Foundation

public struct DeviceInfo: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let bus: UInt32
    public let address: UInt8

    public init(id: String, name: String, bus: UInt32, address: UInt8) {
        self.id = id; self.name = name; self.bus = bus; self.address = address
    }
}

public struct StorageInfo: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let name: String
    public let capacity: UInt64
    public let freeSpace: UInt64

    public init(id: UInt32, name: String, capacity: UInt64, freeSpace: UInt64) {
        self.id = id; self.name = name; self.capacity = capacity; self.freeSpace = freeSpace
    }
}

public struct RemoteItem: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let parentID: UInt32
    public let storageID: UInt32
    public let name: String
    public let size: UInt64
    public let modified: Date?
    public let isDirectory: Bool

    public init(id: UInt32, parentID: UInt32, storageID: UInt32, name: String,
                size: UInt64, modified: Date?, isDirectory: Bool) {
        self.id = id; self.parentID = parentID; self.storageID = storageID
        self.name = name; self.size = size; self.modified = modified; self.isDirectory = isDirectory
    }
}

public struct TransferUpdate: Sendable {
    public let completed: UInt64
    public let total: UInt64
    public var fraction: Double { total == 0 ? 0 : min(1, Double(completed) / Double(total)) }

    public init(completed: UInt64, total: UInt64) {
        self.completed = completed; self.total = total
    }
}

public enum AndroidMTPError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let message): return message }
    }
}
