import CryptoKit
import Foundation

private struct DeviceCheckManifest: Decodable {
    let folder: String
    let sha256: [String: String]
}

@main
struct DeviceRoundtrip {
    static func main() {
        setbuf(stdout, nil)
        Task { await run() }
        RunLoop.main.run()
    }

    static func run() async {
        let service = DeviceFileService()
        do {
            guard CommandLine.arguments.count == 2 else {
                throw AndroidMTPError.message("Provide the project-local device-test directory.")
            }
            let base = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let manifest = try JSONDecoder().decode(DeviceCheckManifest.self,
                from: Data(contentsOf: base.appendingPathComponent("manifest.json")))
            try FileSafety.validateName(manifest.folder)
            guard manifest.folder.hasPrefix("AndroidMTP-Test-") else {
                throw AndroidMTPError.message("Only a generated AndroidMTP test folder may be uploaded.")
            }
            let source = base.appendingPathComponent("upload").appendingPathComponent(manifest.folder)
            let devices = try await service.scan()
            guard devices.count == 1, let device = devices.first else {
                throw AndroidMTPError.message("Connect exactly one unlocked Android device in File transfer mode.")
            }
            let storages = try await service.connect(device)
            guard let storage = storages.first else {
                throw AndroidMTPError.message("The phone has no accessible storage.")
            }
            print("Connected to MTP storage.")
            try await service.upload(localURL: source, storageID: storage.id, parentID: UInt32.max, progress: { _ in })
            let root = try await service.list(storageID: storage.id, parentID: UInt32.max)
            guard let folder = root.first(where: { $0.name == manifest.folder && $0.isDirectory }) else {
                throw AndroidMTPError.message("The uploaded test folder was not found.")
            }
            print("Recursive folder upload passed.")
            let renamed = manifest.folder + "-verified"
            try await service.rename(folder, to: renamed)
            guard let renamedFolder = try await service.list(storageID: storage.id, parentID: UInt32.max)
                .first(where: { $0.name == renamed && $0.isDirectory }) else {
                throw AndroidMTPError.message("The renamed test folder was not found.")
            }
            print("Folder rename passed.")
            let resultDirectory = base.appendingPathComponent("results").appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: resultDirectory, withIntermediateDirectories: true)
            let downloaded = resultDirectory.appendingPathComponent(renamed)
            try await service.download(renamedFolder, to: downloaded, progress: { _ in })
            for (relative, expected) in manifest.sha256 {
                let data = try Data(contentsOf: downloaded.appendingPathComponent(relative))
                let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                guard actual == expected else {
                    throw AndroidMTPError.message("Round-trip hash mismatch for a test file.")
                }
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: downloaded.appendingPathComponent("empty-folder").path,
                                                 isDirectory: &isDirectory), isDirectory.boolValue else {
                throw AndroidMTPError.message("The empty test folder did not survive the round trip.")
            }
            // Repeating the download must reject an existing destination before changing it.
            do {
                try await service.download(renamedFolder, to: downloaded, progress: { _ in })
                throw AndroidMTPError.message("An existing destination was unexpectedly replaced.")
            } catch AndroidMTPError.message(let message) {
                guard message.contains("already exists") else { throw AndroidMTPError.message(message) }
            }
            let evidence: [String: Any] = ["remoteFolder": renamed, "filesVerified": manifest.sha256.count,
                                         "sha256": manifest.sha256, "emptyFolderVerified": true,
                                         "existingDestinationRejected": true]
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: resultDirectory.appendingPathComponent("result.json"))
            await service.disconnect()
            print("Round-trip SHA-256 checks passed for \(manifest.sha256.count) files, including Unicode names.")
            print("Empty-folder preservation and existing-destination protection passed.")
            print("Test folder left on Android: \(renamed)")
            print("Evidence: \(resultDirectory.appendingPathComponent("result.json").path)")
            exit(0)
        } catch {
            await service.disconnect()
            fputs("Device test stopped: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
