import AppKit
import Foundation

actor GalleryTransport: MTPTransport {
    var calls = 0
    var active = 0
    var maximumActive = 0
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    func scan() async throws -> [DeviceInfo] { [DeviceInfo(id: "test", name: "Gallery test", bus: 0, address: 0)] }
    func connect(_ device: DeviceInfo) async throws -> [StorageInfo] { [StorageInfo(id: 1, name: "Test", capacity: 1000, freeSpace: 500)] }
    func disconnect() async {}
    func list(storageID: UInt32, parentID: UInt32) async throws -> [RemoteItem] { [] }
    func createFolder(name: String, storageID: UInt32, parentID: UInt32) async throws {}
    func rename(_ item: RemoteItem, to name: String) async throws {}
    func delete(_ item: RemoteItem) async throws {}
    func upload(localURL: URL, storageID: UInt32, parentID: UInt32, progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {}
    func thumbnail(_ item: RemoteItem) async throws -> Data? { item.id == 5 ? bytes : nil }
    func download(_ item: RemoteItem, to url: URL, progress: @escaping @Sendable (TransferUpdate) -> Void) async throws {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 50_000_000)
        try (item.name.hasPrefix("broken") ? Data([0, 1]) : bytes).write(to: url)
    }
    nonisolated func cancelTransfers() {}
}

@main struct GalleryChecks {
    @MainActor static func main() async throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
        let bytes = bitmap.representation(using: .png, properties: [:])!
        func photo(_ id: UInt32, _ name: String, size: UInt64 = 100) -> RemoteItem {
            RemoteItem(id: id, parentID: 0, storageID: 1, name: name, size: size, modified: nil, isDirectory: false)
        }
        let first = photo(1, "first.png"), second = photo(2, "第二張.PNG")
        precondition(PhotoGalleryModel.isPhoto(first) && PhotoGalleryModel.isPhoto(second))
        precondition(!PhotoGalleryModel.isPhoto(photo(9, "document.txt")))
        let transport = GalleryTransport(bytes: bytes)
        let model = PhotoGalleryModel(photos: [first, second], selected: first, service: transport)
        model.start()
        try await Task.sleep(nanoseconds: 10_000_000)
        model.select(1)
        for _ in 0..<100 where model.thumbnails.count < 2 || model.image == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(model.current.id == second.id && model.image != nil && model.thumbnails.count == 2)
        precondition(model.image!.size.width == 8 && model.image!.size.height == 4)
        model.select(-1); precondition(model.index == 1)
        await model.finish()
        let concurrency = await transport.maximumActive
        precondition(concurrency == 1, "Photo changes must not overlap MTP reads")
        let count = await transport.calls
        precondition(count == 2, "Cached images should not be downloaded twice")

        let broken = photo(3, "broken.png"), huge = photo(4, "huge.jpg", size: 101 * 1024 * 1024)
        let failures = PhotoGalleryModel(photos: [broken, huge], selected: broken, service: transport)
        failures.start()
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(failures.image == nil && !failures.message.isEmpty)
        failures.select(1)
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(failures.message.contains("No small preview"))
        await failures.finish()
        let afterFailures = await transport.calls
        precondition(afterFailures == 3, "Large originals must not be fetched automatically")

        let large = photo(5, "camera.jpg", size: 40 * 1024 * 1024)
        let thumbnailOnly = PhotoGalleryModel(photos: [large], selected: large, service: transport)
        thumbnailOnly.start()
        for _ in 0..<100 where thumbnailOnly.image == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(thumbnailOnly.image != nil, "Large photos should preview from device thumbnails")
        await thumbnailOnly.finish()
        let afterThumbnail = await transport.calls
        precondition(afterThumbnail == afterFailures, "Previewing a large photo must not download its original")

        let closing = PhotoGalleryModel(photos: [first, second], selected: first, service: transport)
        closing.start()
        try await Task.sleep(nanoseconds: 10_000_000)
        await closing.finish()
        let active = await transport.active
        precondition(active == 0, "Dismissal must await the current read before returning the USB session")
        print("Gallery checks passed: image decoding, Unicode extensions, rapid selection, serialized reads, cache reuse, invalid images, thumbnail-only reads of large photos, small-file fallback, and safe dismissal.")
    }
}
