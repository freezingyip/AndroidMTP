import Foundation

extension MTPService: MTPTransport {}
extension SystemMTPService: MTPTransport {}

/// Prefer macOS's existing device connection so photo import services can keep running.
public actor DeviceFileService: MTPTransport {
    private nonisolated let system: any MTPTransport
    private nonisolated let direct: any MTPTransport
    private var active: (any MTPTransport)?

    public init(system: any MTPTransport = SystemMTPService(),
                direct: any MTPTransport = MTPService()) {
        self.system = system
        self.direct = direct
    }

    public func scan() async throws -> [DeviceInfo] {
        var systemFailure: Error?
        do {
            let devices = try await system.scan()
            if !devices.isEmpty { return devices }
        } catch {
            systemFailure = error
        }

        let devices = try await direct.scan()
        if devices.isEmpty, let systemFailure { throw systemFailure }
        return devices
    }

    public func connect(_ device: DeviceInfo) async throws -> [StorageInfo] {
        await disconnect()
        let selected = device.id.hasPrefix("system:") ? system : direct
        do {
            let storages = try await selected.connect(device)
            active = selected
            return storages
        } catch {
            await selected.disconnect()
            throw error
        }
    }

    public func disconnect() async {
        active = nil
        await system.disconnect()
        await direct.disconnect()
    }

    public nonisolated func cancelTransfers() {
        system.cancelTransfers()
        direct.cancelTransfers()
    }

    public func list(storageID: UInt32, parentID: UInt32) async throws -> [RemoteItem] {
        try await connectedTransport().list(storageID: storageID, parentID: parentID)
    }

    public func createFolder(name: String, storageID: UInt32, parentID: UInt32) async throws {
        try await connectedTransport().createFolder(name: name, storageID: storageID, parentID: parentID)
    }

    public func rename(_ item: RemoteItem, to name: String) async throws {
        try await connectedTransport().rename(item, to: name)
    }

    public func delete(_ item: RemoteItem) async throws {
        try await connectedTransport().delete(item)
    }

    public func upload(localURL: URL, storageID: UInt32, parentID: UInt32,
                       progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        try await connectedTransport().upload(localURL: localURL, storageID: storageID,
                                              parentID: parentID, progress: progress)
    }

    public func download(_ item: RemoteItem, to localURL: URL,
                         progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        try await connectedTransport().download(item, to: localURL, progress: progress)
    }

    private func connectedTransport() throws -> any MTPTransport {
        guard let active else { throw AndroidMTPError.message("Connect an Android device first.") }
        return active
    }
}
