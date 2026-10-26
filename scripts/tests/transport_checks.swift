import Foundation

private enum TransportCheckError: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

private final class LockedCancellationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private actor FakeTransport: MTPTransport {
    struct Snapshot: Sendable {
        let scanCount: Int
        let connectIDs: [String]
        let disconnectCount: Int
        let operations: [String]
        let connected: Bool
    }

    private let inventory: [DeviceInfo]
    private let marker: String
    private let failScan: Bool
    private let failConnect: Bool
    private var scanCount = 0
    private var connectIDs: [String] = []
    private var disconnectCount = 0
    private var operations: [String] = []
    private var connected = false
    private nonisolated let cancellations = LockedCancellationCount()

    init(_ marker: String, inventory: [DeviceInfo], failScan: Bool = false, failConnect: Bool = false) {
        self.marker = marker
        self.inventory = inventory
        self.failScan = failScan
        self.failConnect = failConnect
    }

    func snapshot() -> Snapshot {
        Snapshot(scanCount: scanCount, connectIDs: connectIDs, disconnectCount: disconnectCount,
                 operations: operations, connected: connected)
    }

    nonisolated var cancellationCount: Int { cancellations.value }
    nonisolated func cancelTransfers() { cancellations.increment() }

    func scan() async throws -> [DeviceInfo] {
        scanCount += 1
        if failScan { throw TransportCheckError.failed("\(marker) scan failed") }
        return inventory
    }

    func connect(_ device: DeviceInfo) async throws -> [StorageInfo] {
        connectIDs.append(device.id)
        if failConnect { throw TransportCheckError.failed("\(marker) connect failed") }
        connected = true
        return [StorageInfo(id: 7, name: marker, capacity: 100, freeSpace: 80)]
    }

    func disconnect() async {
        disconnectCount += 1
        connected = false
    }

    private func record(_ operation: String) throws {
        guard connected else { throw TransportCheckError.failed("Fake \(marker) has no session") }
        operations.append(operation)
    }

    func list(storageID: UInt32, parentID: UInt32) async throws -> [RemoteItem] {
        try record("list")
        return [RemoteItem(id: 9, parentID: parentID, storageID: storageID, name: marker,
                           size: 1, modified: nil, isDirectory: false)]
    }

    func createFolder(name: String, storageID: UInt32, parentID: UInt32) async throws { try record("mkdir") }
    func rename(_ item: RemoteItem, to name: String) async throws { try record("rename") }
    func delete(_ item: RemoteItem) async throws { try record("delete") }
    func upload(localURL: URL, storageID: UInt32, parentID: UInt32,
                progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        try record("upload")
        progress(TransferUpdate(completed: 1, total: 1))
    }
    func download(_ item: RemoteItem, to localURL: URL,
                  progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        try record("download")
        progress(TransferUpdate(completed: 1, total: 1))
    }
}

@main
private struct TransportChecks {
    // Deliberately identical display names and USB fields: only opaque IDs route requests.
    static let systemDevice = DeviceInfo(id: "system:opaque-camera-uuid", name: "Same Android", bus: 0, address: 0)
    static let directDevice = DeviceInfo(id: "usb:opaque-direct-id", name: "Same Android", bus: 0, address: 0)

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TransportCheckError.failed("Transport check failed: \(message)") }
    }

    static func rejects(_ message: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch { return }
        throw TransportCheckError.failed("Transport check failed: expected rejection for \(message)")
    }

    static func main() async throws {
        try await systemDiscoveryHasPriority()
        try await discoveryFallsBackAfterEmptyOrFailedSystemScan()
        try await opaqueIDsRouteEveryOperation()
        try await failedReconnectLeavesNoActiveSession()
        try await disconnectPreventsFurtherListing()
        try await cancellationReachesBothTransportsConcurrently()
        print("Hardware-free transport discovery, routing, connection lifetime, and cancellation checks passed.")
    }

    static func systemDiscoveryHasPriority() async throws {
        let system = FakeTransport("system", inventory: [systemDevice])
        let direct = FakeTransport("direct", inventory: [directDevice])
        let coordinator = DeviceFileService(system: system, direct: direct)
        let devices = try await coordinator.scan()
        let systemState = await system.snapshot()
        let directState = await direct.snapshot()
        try require(devices == [systemDevice], "system discovery must return only the system inventory")
        try require(systemState.scanCount == 1, "system discovery must run")
        try require(directState.scanCount == 0, "avoid duplicate raw discovery when system devices exist")
    }

    static func discoveryFallsBackAfterEmptyOrFailedSystemScan() async throws {
        for failScan in [false, true] {
            let system = FakeTransport("system", inventory: [], failScan: failScan)
            let direct = FakeTransport("direct", inventory: [directDevice])
            let coordinator = DeviceFileService(system: system, direct: direct)
            let devices = try await coordinator.scan()
            let systemState = await system.snapshot()
            let directState = await direct.snapshot()
            try require(devices == [directDevice], "direct discovery must survive an empty or failed system scan")
            try require(systemState.scanCount == 1 && directState.scanCount == 1, "try each fallback scanner once")
        }
    }

    static func exerciseOperations(_ coordinator: DeviceFileService, marker: String) async throws {
        let items = try await coordinator.list(storageID: 7, parentID: UInt32.max)
        try require(items.first?.name == marker, "listing must reach the selected transport")
        let item = items[0]
        try await coordinator.createFolder(name: "test", storageID: 7, parentID: UInt32.max)
        try await coordinator.rename(item, to: "renamed")
        try await coordinator.delete(item)
        // Fake transports record requests only: these URLs are never read, written, or created.
        let unusedURL = URL(fileURLWithPath: "/not-used-by-fake-transport")
        try await coordinator.upload(localURL: unusedURL, storageID: 7, parentID: UInt32.max, progress: { _ in })
        try await coordinator.download(item, to: unusedURL, progress: { _ in })
    }

    static func opaqueIDsRouteEveryOperation() async throws {
        let system = FakeTransport("system", inventory: [systemDevice])
        let direct = FakeTransport("direct", inventory: [directDevice])
        let coordinator = DeviceFileService(system: system, direct: direct)
        let expectedOperations = ["list", "mkdir", "rename", "delete", "upload", "download"]

        let systemStorage = try await coordinator.connect(systemDevice)
        try require(systemStorage.first?.name == "system", "system prefix must select the system transport")
        try await exerciseOperations(coordinator, marker: "system")
        let initialSystem = await system.snapshot()
        let initialDirect = await direct.snapshot()
        try require(initialSystem.connectIDs == [systemDevice.id], "pass the exact system ID through")
        try require(initialSystem.operations == expectedOperations && initialDirect.operations.isEmpty,
                    "all system operations must stay on the selected transport")

        let directStorage = try await coordinator.connect(directDevice)
        try require(directStorage.first?.name == "direct", "non-system ID must select the direct transport")
        try await exerciseOperations(coordinator, marker: "direct")
        let finalSystem = await system.snapshot()
        let finalDirect = await direct.snapshot()
        try require(finalDirect.connectIDs == [directDevice.id], "pass the exact direct ID through")
        try require(finalDirect.operations == expectedOperations && finalSystem.operations == expectedOperations,
                    "new direct operations must not reach the prior system session")
        try require(!finalSystem.connected && finalDirect.connected, "switching transport must close the previous session")
        try require(finalSystem.disconnectCount == 2 && finalDirect.disconnectCount == 2,
                    "each connection attempt must first release both owned sessions")
        await coordinator.disconnect()
    }

    static func failedReconnectLeavesNoActiveSession() async throws {
        let system = FakeTransport("system", inventory: [systemDevice])
        let direct = FakeTransport("direct", inventory: [directDevice], failConnect: true)
        let coordinator = DeviceFileService(system: system, direct: direct)
        _ = try await coordinator.connect(systemDevice)
        try await rejects("failed direct connection") { _ = try await coordinator.connect(directDevice) }
        try await rejects("listing after a failed reconnect") {
            _ = try await coordinator.list(storageID: 7, parentID: UInt32.max)
        }
        let systemState = await system.snapshot()
        let directState = await direct.snapshot()
        try require(!systemState.connected && !directState.connected, "failed reconnect must leave both sessions closed")
        try require(systemState.operations.isEmpty && directState.operations.isEmpty,
                    "a failed connection must not retain a usable old transport")
    }

    static func disconnectPreventsFurtherListing() async throws {
        let system = FakeTransport("system", inventory: [systemDevice])
        let direct = FakeTransport("direct", inventory: [directDevice])
        let coordinator = DeviceFileService(system: system, direct: direct)
        _ = try await coordinator.connect(systemDevice)
        _ = try await coordinator.list(storageID: 7, parentID: UInt32.max)
        await coordinator.disconnect()
        try await rejects("listing after disconnect") {
            _ = try await coordinator.list(storageID: 7, parentID: UInt32.max)
        }
        let systemState = await system.snapshot()
        let directState = await direct.snapshot()
        try require(systemState.operations == ["list"], "disconnected listing must be rejected before reaching a backend")
        try require(!systemState.connected && !directState.connected, "disconnect must close all owned sessions")
    }

    static func cancellationReachesBothTransportsConcurrently() async throws {
        let system = FakeTransport("system", inventory: [])
        let direct = FakeTransport("direct", inventory: [])
        let coordinator = DeviceFileService(system: system, direct: direct)
        let requestCount = 64
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<requestCount { group.addTask { coordinator.cancelTransfers() } }
        }
        try require(system.cancellationCount == requestCount, "every cancellation must reach the system transport")
        try require(direct.cancellationCount == requestCount, "every cancellation must reach the direct transport")
    }
}
