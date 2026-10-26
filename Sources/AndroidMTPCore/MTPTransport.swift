import Foundation

/// The file browser uses the same operations for system-managed and direct USB sessions.
public protocol MTPTransport: Sendable {
    func scan() async throws -> [DeviceInfo]
    func connect(_ device: DeviceInfo) async throws -> [StorageInfo]
    func disconnect() async
    func list(storageID: UInt32, parentID: UInt32) async throws -> [RemoteItem]
    func createFolder(name: String, storageID: UInt32, parentID: UInt32) async throws
    func rename(_ item: RemoteItem, to name: String) async throws
    func delete(_ item: RemoteItem) async throws
    func upload(localURL: URL, storageID: UInt32, parentID: UInt32,
                progress: @escaping @Sendable (TransferUpdate) -> Void) async throws
    func download(_ item: RemoteItem, to localURL: URL,
                  progress: @escaping @Sendable (TransferUpdate) -> Void) async throws
    /// Implementations must be callable while an isolated transfer is in progress.
    func cancelTransfers()
}
