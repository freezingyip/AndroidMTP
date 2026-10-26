import AndroidMTPCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ADBPanelModel: ObservableObject {
    @Published var devices: [ADBDevice] = []
    @Published var selectedID: String?
    @Published var isBusy = false
    @Published var status = "Optional. Standard MTP file access works without this."
    @Published var errorMessage: String?
    private let service = ADBService()

    var selectedDevice: ADBDevice? { devices.first { $0.id == selectedID } }

    func scan() async {
        guard !isBusy else { return }
        isBusy = true
        status = "Checking authorized debugging devices…"
        defer { isBusy = false }
        do {
            guard await service.availableExecutable() != nil else {
                throw AndroidMTPError.message("ADB is not installed. Install Android platform tools, or keep using the standard MTP browser without debugging.")
            }
            devices = try await service.devices()
            selectedID = devices.first(where: \.isAuthorized)?.id ?? devices.first?.id
            status = devices.isEmpty ? "No debugging devices found. Check USB debugging and the authorization prompt on your phone." : "Choose an authorized debugging device."
        } catch {
            status = "Debugging connection unavailable"
            errorMessage = error.localizedDescription
        }
    }

    func chooseAPK() {
        guard !isBusy, let device = selectedDevice, device.isAuthorized else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an APK to install"
        panel.prompt = "Install APK"
        panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Install only an APK from a source you trust. Existing apps will not be replaced."
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                isBusy = true
                status = "Installing \(url.lastPathComponent)…"
                defer { isBusy = false }
                do {
                    let output = try await service.installAPK(at: url, on: device.id)
                    status = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if status.isEmpty { status = "APK installed" }
                } catch {
                    status = "APK installation could not finish"
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct ADBPanel: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = ADBPanelModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Optional debugging features", systemImage: "wrench.and.screwdriver")
                .font(.title2.weight(.semibold))
            Text("Standard USB MTP remains the main file browser. USB debugging adds APK installation through Android Debug Bridge (ADB).")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                Text("To use this optional mode").font(.headline)
                Text("Enable USB debugging in your phone’s Developer options, connect the cable, and approve this Mac on the phone.")
                Text("Debugging gives the approved Mac broader control. Only approve a computer you trust; you can turn debugging off when finished.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            if !model.devices.isEmpty {
                Picker("Debugging device", selection: $model.selectedID) {
                    ForEach(model.devices) { device in
                        Text("\(device.name) · \(device.state)").tag(Optional(device.id))
                    }
                }
                .disabled(model.isBusy)
            }
            HStack {
                Button("Find debugging devices") { Task { await model.scan() } }
                    .disabled(model.isBusy)
                Button("Install APK…", action: model.chooseAPK)
                    .disabled(model.isBusy || model.selectedDevice?.isAuthorized != true)
            }
            if model.isBusy { ProgressView().progressViewStyle(.linear) }
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Text("Wireless pairing and app management are planned additions. This version installs individual APK files without replacing an existing app.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy)
            }
        }
        .padding(26)
        .frame(width: 560)
        .interactiveDismissDisabled(model.isBusy)
        .alert("Debugging feature unavailable", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
}
