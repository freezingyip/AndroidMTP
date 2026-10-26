import AppKit
import AndroidMTPCore
import SwiftUI
import UniformTypeIdentifiers

struct BrowserView: View {
    @ObservedObject var model: BrowserModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
        } detail: {
            VStack(spacing: 0) {
                if model.isConnected {
                    breadcrumbs
                    Divider()
                    fileBrowser
                } else if model.showConnectionSheet {
                    VStack {
                        Spacer(minLength: 0)
                        connectionPanel
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    welcome
                }
                Divider()
                statusBar
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Android file browser")
            .navigationTitle(model.isConnected ? model.currentFolderName : "AndroidMTP")
            .toolbar { toolbar }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Android file transfer")
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.clipboardDidChange()
        }
        .sheet(isPresented: $model.showPhotoGallery, onDismiss: {
            Task { await model.closePhotoGallery() }
        }) {
            if let gallery = model.photoGallery { PhotoGalleryView(model: gallery) }
        }
        .sheet(isPresented: $model.showAdvancedSheet) { ADBPanel() }
        .sheet(item: $model.namePrompt) { prompt in nameSheet(prompt) }
        .alert("Couldn’t complete the operation", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .confirmationDialog("Delete \(model.selectedItems.count) selected item\(model.selectedItems.count == 1 ? "" : "s") permanently?", isPresented: $model.showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { Task { await model.deleteSelection() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MTP has no standard Trash. This cannot be undone. Only files and empty folders can be deleted in this version.")
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "smartphone")
                    .font(.system(size: 28))
                    .foregroundStyle(.green)
                    .frame(width: 35)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.activeDevice?.name ?? "Your Android")
                        .font(.headline)
                        .lineLimit(1)
                    Label(model.isConnected ? "USB · MTP" : "Not connected", systemImage: model.isConnected ? "circle.fill" : "circle")
                        .font(.caption)
                        .foregroundStyle(model.isConnected ? .green : .secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            List {
                Section("Storage") {
                    if model.storages.isEmpty {
                        Text("Connect a device to see storage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 4)
                    }
                    ForEach(model.storages) { storage in
                        Button {
                            Task { await model.openStorage(storage) }
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "internaldrive")
                                    .foregroundStyle(model.storageID == storage.id ? Color.accentColor : Color.secondary)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(storage.name).lineLimit(2)
                                    Text("\(BrowserModel.byteCount(storage.freeSpace)) free")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(storage.name)
                        .accessibilityValue("\(BrowserModel.byteCount(storage.freeSpace)) free")
                        .disabled(!model.canAct)
                        .listRowBackground(model.storageID == storage.id && model.path.isEmpty ? Color.accentColor.opacity(0.12) : Color.clear)
                    }
                }
                if !model.quickFolders.isEmpty {
                    Section("Quick Access") {
                        ForEach(model.quickFolders) { folder in
                            Button {
                                Task { await model.openQuickFolder(folder) }
                            } label: {
                                Label(folder.name == "DCIM" ? "Camera" : folder.name, systemImage: folderIcon(folder.name))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(folder.name == "DCIM" ? "Camera" : folder.name)")
                            .disabled(!model.canAct)
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            Spacer(minLength: 0)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("USB debugging not needed", systemImage: "checkmark.shield")
                    .font(.caption)
                Text("Standard file access over USB.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Device and storage")
    }

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 28)
                    .fill(Color.green.opacity(0.09))
                    .frame(width: 112, height: 112)
                Image(systemName: "cable.connector")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.green)
            }
            VStack(spacing: 8) {
                Text("Your Android files, on your Mac")
                    .font(.system(size: 25, weight: .semibold))
                Text("Connect with a USB cable. No USB debugging required.")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                setupStep("1", "Unlock your Android phone.")
                setupStep("2", "Tap its USB notification and choose File transfer / Android Auto.")
                setupStep("3", "Allow file access on your phone if asked, then connect below.")
            }
            .padding(20)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            Button {
                model.showConnectionSheet = true
                Task { await model.scan() }
            } label: {
                Label("Connect Android", systemImage: "cable.connector")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("Connect Android")
            .controlSize(.large)
            .disabled(model.isBusy)
            Text("Internal storage and SD cards · Files and folders · No account")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Android connection setup")
    }

    private func setupStep(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .background(.secondary.opacity(0.13), in: Circle())
            Text(text).font(.callout)
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.goToBreadcrumb(max(0, model.path.count - 1)) }
            } label: { Image(systemName: "chevron.left") }
            .buttonStyle(.borderless)
            .help("Go to parent folder")
            .accessibilityLabel("Go to parent folder")
            .disabled(model.path.isEmpty || !model.canAct)
            Divider().frame(height: 17)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(model.currentStorage?.name ?? "Storage") { Task { await model.goToBreadcrumb(0) } }
                        .accessibilityLabel("Open storage root")
                    ForEach(Array(model.path.enumerated()), id: \.element.id) { index, folder in
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        Button(folder.name) { Task { await model.goToBreadcrumb(index + 1) } }
                            .accessibilityLabel("Open \(folder.name)")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(!model.canAct)
            }
            Spacer(minLength: 10)
            Text("\(model.filteredItems.count) items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder location")
    }

    private var fileBrowser: some View {
        Table(model.filteredItems, selection: $model.selection) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    Image(systemName: item.isDirectory ? "folder.fill" : "doc")
                        .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
                        .frame(width: 21)
                        .accessibilityHidden(true)
                    Text(item.name).lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    model.selection = [item.id]
                    Task { await model.openSelection() }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(item.name)
                .accessibilityValue(item.isDirectory ? "Folder" : "File")
            }
            .width(min: 200, ideal: 420)
            TableColumn("Size") { item in
                Text(item.isDirectory ? "—" : BrowserModel.byteCount(item.size))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 75, ideal: 90, max: 120)
            TableColumn("Modified") { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 140, ideal: 175, max: 210)
            TableColumn("Kind") { item in
                Text(item.isDirectory ? "Folder" : fileKind(item.name)).foregroundStyle(.secondary)
            }
            .width(min: 65, ideal: 90, max: 130)
        }
        .disabled(model.isBusy)
        .contextMenu {
            Button("Open") {
                if let photo = model.selectedPhoto { model.previewPhoto(photo, openOnMac: true) }
                else { Task { await model.openSelection() } }
            }.accessibilityLabel("Open selected item")
                .disabled(!model.canAct || model.selectedItems.count != 1 || (model.selectedPhoto == nil && model.selectedItems.first?.isDirectory != true))
            Button("Preview photo gallery") {
                if let photo = model.selectedPhoto { model.previewPhoto(photo) }
            }.accessibilityLabel("Preview selected photo")
                .disabled(!model.canAct || model.selectedPhoto == nil)
            Button("Copy") { Task { await model.copySelection() } }
                .disabled(!model.canAct || model.selection.isEmpty)
            Button("Paste to upload") { Task { await model.pasteFiles() } }
                .disabled(!model.canPasteFiles)
            Divider()
            Button("Download to Mac…", action: model.chooseDownloadDestination)
                .disabled(!model.canAct || model.selection.isEmpty)
            Button("Rename…", action: model.beginRename)
                .disabled(!model.canAct || model.selection.count != 1)
            Divider()
            Button("Delete permanently…", role: .destructive) { model.showDeleteConfirmation = true }
                .disabled(!model.canAct || model.selection.isEmpty)
        }
        .overlay {
            if model.filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: model.search.isEmpty ? "folder" : "magnifyingglass")
                        .font(.system(size: 36, weight: .light))
                    Text(model.search.isEmpty ? "This folder is empty" : "No matching files")
                        .font(.headline)
                    if model.search.isEmpty { Text("Drop files here or choose Upload.").font(.callout) }
                }
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if model.isDropTarget {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(7)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $model.isDropTarget) { providers in
            guard model.canAct else { return false }
            Task {
                var urls: [URL] = []
                for provider in providers {
                    let url: URL? = await withCheckedContinuation { continuation in
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
                    }
                    if let url, url.isFileURL { urls.append(url) }
                }
                await model.upload(urls)
            }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files in \(model.currentFolderName)")
        .focusedObject(model)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Button {
                if let photo = model.selectedPhoto { model.previewPhoto(photo) }
                else if let photo = model.filteredItems.first(where: PhotoGalleryModel.isPhoto) { model.previewPhoto(photo) }
            } label: { Label("Photo Gallery", systemImage: "photo.on.rectangle") }
                .accessibilityLabel("Photo gallery")
                .help("Preview photos in this folder")
                .disabled(!model.canAct || !model.filteredItems.contains(where: PhotoGalleryModel.isPhoto))
            Button(action: model.chooseUploads) { Label("Upload", systemImage: "arrow.up.doc") }
                .accessibilityLabel("Upload to Android")
                .help("Upload files or folders to Android (⌘U)")
                .disabled(!model.canAct)
            Button(action: model.chooseDownloadDestination) { Label("Download", systemImage: "arrow.down.doc") }
                .accessibilityLabel("Download to Mac")
                .help("Download selected items to your Mac (⌘D)")
                .disabled(!model.canAct || model.selection.isEmpty)
            Button(action: model.beginNewFolder) { Label("New Folder", systemImage: "folder.badge.plus") }
                .accessibilityLabel("New folder")
                .disabled(!model.canAct)
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .accessibilityLabel("Refresh files")
                .disabled(!model.canAct)
            Menu {
                if model.isConnected {
                    Button("Disconnect device") { Task { await model.disconnect() } }
                } else {
                    Button("Connect Android…") {
                        model.showConnectionSheet = true
                        Task { await model.scan() }
                    }
                }
                Divider()
                Button("Optional debugging features…") { model.showAdvancedSheet = true }
            } label: { Label(model.isConnected ? "USB MTP" : "Connect", systemImage: "cable.connector") }
                .accessibilityLabel("Device connection options")
                .disabled(model.isBusy)
        }
        ToolbarItem(placement: .automatic) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search this folder", text: $model.search)
                    .textFieldStyle(.plain)
                    .frame(width: 155)
                    .accessibilityLabel("Search this folder")
            }
            .padding(7)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
            .disabled(!model.canAct)
        }
    }

    private var statusBar: some View {
        VStack(spacing: 9) {
            if model.isTransferring {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.transferName).font(.callout).lineLimit(1)
                        ProgressView(value: model.transferProgress).progressViewStyle(.linear)
                            .accessibilityLabel("Transfer progress")
                    }
                    Text(model.transferBytes).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button("Cancel", action: model.cancelTransfers)
                }
            }
            HStack(spacing: 8) {
                if model.isBusy && !model.isTransferring {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 16, height: 16)
                        .accessibilityLabel("Loading device contents")
                } else {
                    Image(systemName: model.isConnected ? "circle.fill" : "circle")
                        .font(.system(size: 7))
                        .foregroundStyle(model.isConnected ? Color.green : Color.secondary)
                }
                Text(model.status)
                Spacer()
                if !model.selection.isEmpty { Text("\(model.selection.count) selected") }
                Text("MTP · No debugging required")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transfer status")
    }

    private var connectionPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Connect your Android", systemImage: "cable.connector")
                .font(.title2.weight(.semibold))
            Text("Unlock your phone, connect a data-capable USB cable, and select File transfer in the phone’s USB notification. USB debugging can stay off.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.devices.isEmpty {
                HStack {
                    Image(systemName: model.isBusy ? "antenna.radiowaves.left.and.right" : "smartphone.slash")
                        .font(.title2).foregroundStyle(.secondary)
                    Text(model.isBusy ? "Looking for devices…" : "No devices found. Check the cable and USB mode, then scan again.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            } else {
                Picker("Device", selection: $model.selectedDeviceID) {
                    ForEach(model.devices) { device in Text(device.name).tag(Optional(device.id)) }
                }
                .accessibilityLabel("Android device")
                .disabled(model.isBusy)
            }
            HStack(spacing: 9) {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Connecting to Android")
                }
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Connection status")
            if let error = model.connectionError {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").accessibilityHidden(true)
                    Text(error).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
                .foregroundStyle(.red)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Connection error: \(error)")
            }
            Text("If another MTP app is using the device, finish its transfers and close its connection first.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Scan again") { Task { await model.scan() } }
                    .accessibilityLabel("Scan for Android devices")
                    .disabled(model.isBusy)
                Spacer()
                Button("Cancel") { model.showConnectionSheet = false }
                    .accessibilityLabel("Cancel connection")
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy)
                Button("Connect") { Task { await model.connectSelected() } }
                    .accessibilityLabel("Connect selected Android device")
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || !model.devices.contains(where: { $0.id == model.selectedDeviceID }))
            }
        }
        .padding(26)
        .frame(width: 510)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connect Android device")
    }

    private func nameSheet(_ prompt: BrowserModel.NamePrompt) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(prompt.title).font(.title2.weight(.semibold))
            TextField("Name", text: $model.proposedName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await model.saveName() } }
            Text("Existing items will not be replaced.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { model.namePrompt = nil }.keyboardShortcut(.cancelAction)
                Button(prompt == .newFolder ? "Create" : "Rename") { Task { await model.saveName() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.proposedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func folderIcon(_ name: String) -> String {
        switch name {
        case "DCIM": return "camera"
        case "Download", "Downloads": return "arrow.down.circle"
        case "Pictures": return "photo"
        case "Music": return "music.note"
        case "Movies": return "film"
        default: return "doc.text"
        }
    }

    private func fileKind(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "File" : "\(ext.uppercased()) file"
    }
}
