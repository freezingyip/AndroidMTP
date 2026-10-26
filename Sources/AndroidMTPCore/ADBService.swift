import Foundation
import Darwin

/// A device visible to the optional Android Debug Bridge connection.
public struct ADBDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let state: String
    public var isAuthorized: Bool { state == "device" }

    public init(id: String, name: String, state: String) {
        self.id = id
        self.name = name
        self.state = state
    }
}

/// This service is independent of MTP and never enables debugging or grants access.
/// Its commands must only be requested by the user through the advanced features UI.
public actor ADBService {
    public init() {}

    /// Finds an existing installation without launching ADB or starting its server.
    public func availableExecutable() -> URL? {
        let sdkPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Android/sdk/platform-tools/adb").path
        let paths = [
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
            sdkPath,
            "/Applications/AndroidFileSync.app/Contents/Resources/adb"
        ]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    public func devices() async throws -> [ADBDevice] {
        let result = try await ADBProcess.run(
            executable: try executable(), arguments: ["devices", "-l"], timeout: 20
        )
        guard result.status == 0 else {
            throw AndroidMTPError.message(Self.commandError(result.output))
        }
        return Self.parseDeviceList(result.output)
    }

    /// Installs a new package only. Existing apps are not silently replaced.
    public func installAPK(at url: URL, on serial: String) async throws -> String {
        let apkURL = try Self.validatedAPKURL(url)
        guard !serial.isEmpty, !serial.contains("\0"),
              serial.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw AndroidMTPError.message("Choose a connected Android device first.")
        }
        let connected = try await devices()
        guard connected.contains(where: { $0.id == serial && $0.isAuthorized }) else {
            throw AndroidMTPError.message(
                "The selected device is not authorized for debugging. Unlock your phone and approve this Mac, then scan again."
            )
        }
        let result = try await ADBProcess.run(
            executable: try executable(),
            arguments: ["-s", serial, "install", apkURL.path],
            timeout: 120
        )
        let lines = result.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let failed = lines.contains { $0.hasPrefix("Failure") || $0.hasPrefix("adb: error") }
        guard result.status == 0, !failed, lines.contains("Success") else {
            throw AndroidMTPError.message(Self.commandError(result.output))
        }
        return "Installed \(apkURL.lastPathComponent)."
    }

    private func executable() throws -> URL {
        guard let url = availableExecutable() else {
            throw AndroidMTPError.message(
                "Android Platform Tools was not found. Install it to use optional debugging features. Normal MTP file access does not require it."
            )
        }
        return url
    }

    static func parseDeviceList(_ output: String) -> [ADBDevice] {
        let states: Set<String> = [
            "device", "offline", "unauthorized", "recovery", "bootloader",
            "sideload", "rescue", "host", "no"
        ]
        var seen = Set<String>()
        return output.components(separatedBy: .newlines).compactMap { line in
            let words = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard words.count >= 2, states.contains(words[1]),
                  !words[0].hasPrefix("*"), seen.insert(words[0]).inserted else { return nil }
            let model = words.first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") }
            let state = words[1] == "no" && words.count > 2 && words[2] == "permissions"
                ? "no permissions" : words[1]
            return ADBDevice(id: words[0], name: model?.isEmpty == false ? model! : words[0], state: state)
        }
    }

    static func validatedAPKURL(_ url: URL) throws -> URL {
        guard url.isFileURL, url.pathExtension.lowercased() == "apk" else {
            throw AndroidMTPError.message("Choose an APK file to install.")
        }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let values = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? 0) >= 4,
              FileManager.default.isReadableFile(atPath: resolved.path) else {
            throw AndroidMTPError.message("The APK must be a readable file on your Mac.")
        }
        let handle = try FileHandle(forReadingFrom: resolved)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data([0x50, 0x4b, 0x03, 0x04]) else {
            throw AndroidMTPError.message("This file does not appear to be an Android APK archive.")
        }
        return resolved
    }

    private static func commandError(_ output: String) -> String {
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "ADB did not confirm that the operation completed." : String(message.prefix(4_000))
    }
}

private struct ADBProcessResult {
    let output: String
    let status: Int32
}

private final class ADBTimeoutState: @unchecked Sendable {
    private let lock = NSLock()
    private var didTimeout = false

    func markTimeout() {
        lock.lock()
        didTimeout = true
        lock.unlock()
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeout
    }
}

private enum ADBProcess {
    static func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> ADBProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let pipe = Pipe()
                process.executableURL = executable
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let state = ADBTimeoutState()
                let timeoutWork = DispatchWorkItem {
                    guard process.isRunning else { return }
                    state.markTimeout()
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
                // Drain output while the process runs so a full pipe cannot deadlock it.
                var output = Data()
                while true {
                    let chunk = pipe.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    if output.count < 1_048_576 {
                        output.append(chunk.prefix(1_048_576 - output.count))
                    }
                }
                process.waitUntilExit()
                timeoutWork.cancel()
                try? pipe.fileHandleForReading.close()
                if state.timedOut {
                    continuation.resume(throwing: AndroidMTPError.message(
                        "The debugging operation timed out. Check your phone and USB connection, then try again."
                    ))
                } else {
                    continuation.resume(returning: ADBProcessResult(
                        output: String(decoding: output, as: UTF8.self), status: process.terminationStatus
                    ))
                }
            }
        }
    }
}
