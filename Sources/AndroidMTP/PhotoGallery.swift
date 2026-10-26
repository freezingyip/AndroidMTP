import AppKit
import AndroidMTPCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PhotoGalleryModel: ObservableObject {
    let photos: [RemoteItem]
    @Published private(set) var index: Int
    @Published private(set) var thumbnails: [UInt32: NSImage] = [:]
    @Published private(set) var image: NSImage?
    @Published private(set) var message = "Loading photo…"
    @Published private(set) var loading = false
    private let service: any MTPTransport
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AndroidMTP-Photos-\(UUID().uuidString)", isDirectory: true)
    private var originals: [UInt32: URL] = [:]
    private var sizes: [UInt32: UInt64] = [:]
    private var failures: Set<UInt32> = []
    private var errors: [UInt32: String] = [:]
    private var worker: Task<Void, Never>?
    private var stopped = false
    private var openWhenReady: UInt32?
    private var opened: Set<UInt32> = []

    static func isPhoto(_ item: RemoteItem) -> Bool {
        guard !item.isDirectory else { return false }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "avif"].contains(ext) { return true }
        return UTType(filenameExtension: ext)?.conforms(to: .image) == true
    }

    init(photos: [RemoteItem], selected: RemoteItem, service: any MTPTransport) {
        self.photos = photos
        self.index = photos.firstIndex(where: { $0.id == selected.id }) ?? 0
        self.service = service
    }
    var current: RemoteItem { photos[index] }
    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < photos.count }

    func select(_ next: Int) {
        guard photos.indices.contains(next), !stopped else { return }
        index = next
        image = thumbnails[current.id]
        message = errors[current.id] ?? "Loading photo…"
        openWhenReady = nil
        start()
    }
    func start() {
        guard worker == nil, !stopped else { return }
        worker = Task { await run() }
    }
    func openOnMac() {
        if let url = originals[current.id] { NSWorkspace.shared.open(url); opened.insert(current.id) }
        else { openWhenReady = current.id; failures.remove(current.id); start() }
    }
    func retry() { failures.remove(current.id); start() }

    private func run() async {
        defer { worker = nil; loading = false }
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { message = error.localizedDescription; return }
        while !stopped {
            if let id = openWhenReady, let item = photos.first(where: { $0.id == id }) {
                loading = true
                message = "Opening original photo on Mac…"
                do {
                    let url = try await original(item)
                    guard !stopped else { return }
                    NSWorkspace.shared.open(url)
                    opened.insert(id)
                } catch { if !stopped { message = error.localizedDescription } }
                openWhenReady = nil
                continue
            }
            image = thumbnails[current.id]
            let target = !failures.contains(current.id) && thumbnails[current.id] == nil
                ? current : photos.prefix(200).first { thumbnails[$0.id] == nil && !failures.contains($0.id) }
            guard let item = target else { return }
            loading = item.id == current.id
            do {
                var bytes = try await service.thumbnail(item)
                guard !stopped else { return }
                // Some Android files have no generated thumbnail. Only read tiny originals
                // automatically; large originals always require an explicit Open on Mac.
                if bytes == nil, item.size <= 512 * 1024 {
                    bytes = try Data(contentsOf: await original(item))
                }
                guard !stopped else { return }
                if let bytes, let preview = await Self.decode(bytes, pixels: 640) {
                    thumbnails[item.id] = preview
                    if current.id == item.id { image = preview; message = "" }
                } else {
                    failures.insert(item.id)
                    errors[item.id] = "No small preview is available. Choose Open on Mac to load the original photo."
                    if current.id == item.id { message = errors[item.id]! }
                }
            } catch {
                failures.insert(item.id)
                errors[item.id] = error.localizedDescription
                if current.id == item.id { message = error.localizedDescription }
            }
        }
    }

    private func original(_ item: RemoteItem) async throws -> URL {
        if let cached = originals[item.id] { return cached }
        let url = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension((item.name as NSString).pathExtension)
        try await service.download(item, to: url, progress: { _ in })
        originals[item.id] = url
        sizes[item.id] = item.size
        while sizes.values.reduce(0, +) > 512 * 1024 * 1024,
              let victim = originals.keys.first(where: { $0 != item.id && !opened.contains($0) }) {
            if let old = originals.removeValue(forKey: victim) { try? FileManager.default.removeItem(at: old) }
            sizes.removeValue(forKey: victim)
        }
        return url
    }

    private static func decode(_ data: Data, pixels: Int) async -> NSImage? {
        let result: CGImage? = await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            return cg
        }.value
        return result.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
    func finish() async {
        stopped = true
        if worker != nil { service.cancelTransfers() }
        await worker?.value
        for (id, url) in originals where !opened.contains(id) { try? FileManager.default.removeItem(at: url) }
        if opened.isEmpty { try? FileManager.default.removeItem(at: directory) }
        // Open-on-Mac files remain available to the receiving app for this login session.
        // Temporary directories are reclaimed by macOS; no phone files are modified.
    }
}

struct PhotoGalleryView: View {
    @ObservedObject var model: PhotoGalleryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.current.name).font(.headline).lineLimit(1)
                    Text("\(model.index + 1) of \(model.photos.count) photos · \(BrowserModel.byteCount(model.current.size))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open on Mac") { model.openOnMac() }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ZStack {
                Color.black.opacity(0.85)
                if let image = model.image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .frame(maxWidth: 640, maxHeight: 420).padding(16)
                        .accessibilityLabel("Photo preview: \(model.current.name)")
                } else {
                    VStack(spacing: 12) {
                        if model.loading { ProgressView() }
                        Text(model.message).multilineTextAlignment(.center).textSelection(.enabled)
                        if !model.loading { Button("Try again") { model.retry() } }
                    }.padding(40).foregroundStyle(.white)
                }
                HStack {
                    Button { model.select(model.index - 1) } label: { Image(systemName: "chevron.left").font(.title2).padding(10) }
                        .disabled(!model.canGoBack).accessibilityLabel("Previous photo")
                    Spacer()
                    Button { model.select(model.index + 1) } label: { Image(systemName: "chevron.right").font(.title2).padding(10) }
                        .disabled(!model.canGoForward).accessibilityLabel("Next photo")
                }.padding(12)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Array(model.photos.enumerated()), id: \.element.id) { index, item in
                        Button { model.select(index) } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12))
                                    if let thumbnail = model.thumbnails[item.id] {
                                        Image(nsImage: thumbnail).resizable().scaledToFit()
                                    } else { Image(systemName: "photo").font(.title).foregroundStyle(.secondary) }
                                }.frame(width: 90, height: 66)
                                Text(item.name).font(.caption2).lineLimit(1).frame(width: 90)
                            }.padding(5)
                                .background(index == model.index ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel("Preview \(item.name)")
                    }
                }.padding(10)
            }.frame(height: 112)
        }
        .frame(minWidth: 600, idealWidth: 760, minHeight: 440, idealHeight: 600)
        .onMoveCommand { direction in
            if direction == .left { model.select(model.index - 1) }
            if direction == .right { model.select(model.index + 1) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Photo gallery")
        .task { model.start() }
    }
}
