import Foundation

/// Hardware-free checks, compiled alongside Models.swift and ADBService.swift.
@main
struct ADBChecks {
    enum Failure: Error, CustomStringConvertible {
        case expectation(String)
        var description: String {
            switch self { case .expectation(let message): return message }
        }
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.expectation(message) }
    }

    static func rejectsAPK(_ url: URL) throws {
        do {
            _ = try ADBService.validatedAPKURL(url)
        } catch {
            return
        }
        throw Failure.expectation("APK preflight accepted an invalid fixture: \(url.lastPathComponent)")
    }

    static func main() throws {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        ABC123 device usb:1-2 product:husky model:Pixel_8_Pro device:husky transport_id:1
        PHONE456 unauthorized usb:1-3 transport_id:2
        192.168.1.5:37123 offline transport_id:3
        """
        let devices = ADBService.parseDeviceList(output)
        try expect(devices.map(\.id) == ["ABC123", "PHONE456", "192.168.1.5:37123"],
                   "Device parser lost serials or included daemon messages")
        try expect(devices[0].name == "Pixel 8 Pro", "Model display name was not decoded")
        try expect(devices[0].isAuthorized, "A normal device should be available")
        try expect(!devices[1].isAuthorized && !devices[2].isAuthorized,
                   "Unauthorized and offline devices must remain unavailable")

        let noise = """
        adb server version (40) doesn't match this client (41); killing...
        List of devices attached
        DENIED no permissions (missing udev rules?)
        RECOVERY recovery transport_id:7
        DENIED no permissions
        """
        let other = ADBService.parseDeviceList(noise)
        try expect(other.count == 2, "Parser must ignore noise and duplicate serials")
        try expect(other[0].state == "no permissions" && !other[0].isAuthorized,
                   "A denied device must preserve its unavailable state")
        try expect(other[1].state == "recovery" && !other[1].isAuthorized,
                   "A recovery device must not be treated as an authorized install target")
        try expect(ADBService.parseDeviceList("List of devices attached\n\n").isEmpty,
                   "An empty ADB list should produce no devices")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidmtp-adb-checks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let fake = directory.appendingPathComponent("fake.apk")
        try Data("not an archive".utf8).write(to: fake)
        try rejectsAPK(fake)
        let folder = directory.appendingPathComponent("folder.apk", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try rejectsAPK(folder)
        try rejectsAPK(URL(string: "https://example.com/app.apk")!)
        try rejectsAPK(directory.appendingPathComponent("missing.apk"))

        let apk = directory.appendingPathComponent("My App.APK")
        try Data([0x50, 0x4b, 0x03, 0x04, 0, 0, 0, 0]).write(to: apk)
        let accepted = try ADBService.validatedAPKURL(apk)
        try expect(accepted == apk.resolvingSymlinksInPath(),
                   "A readable local APK archive should pass preflight")
        print("ADB checks passed: device states, parser noise, duplicate serials, and APK preflight.")
    }
}
