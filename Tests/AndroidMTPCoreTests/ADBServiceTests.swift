import XCTest
@testable import AndroidMTPCore

final class ADBServiceTests: XCTestCase {
    func testDeviceListSeparatesAuthorizedAndUnavailableDevices() {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        ABC123 device usb:1-2 product:husky model:Pixel_8_Pro device:husky transport_id:1
        PHONE456 unauthorized usb:1-3 transport_id:2
        192.168.1.5:37123 offline transport_id:3
        """
        let devices = ADBService.parseDeviceList(output)
        XCTAssertEqual(devices.map(\.id), ["ABC123", "PHONE456", "192.168.1.5:37123"])
        XCTAssertEqual(devices[0].name, "Pixel 8 Pro")
        XCTAssertTrue(devices[0].isAuthorized)
        XCTAssertFalse(devices[1].isAuthorized)
        XCTAssertFalse(devices[2].isAuthorized)
    }

    func testDeviceListPreservesNoPermissionsStateAndIgnoresNoise() {
        let output = """
        adb server version (40) doesn't match this client (41); killing...
        List of devices attached
        DENIED no permissions (missing udev rules?); see [http://developer.android.com/tools/device.html]
        RECOVERY recovery transport_id:7
        DENIED no permissions
        """
        let devices = ADBService.parseDeviceList(output)
        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].state, "no permissions")
        XCTAssertFalse(devices[0].isAuthorized)
        XCTAssertEqual(devices[1].state, "recovery")
        XCTAssertFalse(devices[1].isAuthorized)
        XCTAssertTrue(ADBService.parseDeviceList("List of devices attached\n\n").isEmpty)
    }

    func testAPKPreflightRejectsDirectoryAndRenamedNonArchive() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidmtp-apk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fake = directory.appendingPathComponent("fake.apk")
        try Data("not an archive".utf8).write(to: fake)
        XCTAssertThrowsError(try ADBService.validatedAPKURL(fake))
        let folder = directory.appendingPathComponent("folder.apk", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ADBService.validatedAPKURL(folder))
        XCTAssertThrowsError(try ADBService.validatedAPKURL(URL(string: "https://example.com/app.apk")!))
    }

    func testAPKPreflightAcceptsReadableLocalArchiveWithUppercaseExtension() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("androidmtp-apk-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let apk = directory.appendingPathComponent("My App.APK")
        try Data([0x50, 0x4b, 0x03, 0x04, 0, 0, 0, 0]).write(to: apk)
        XCTAssertEqual(try ADBService.validatedAPKURL(apk), apk.resolvingSymlinksInPath())
    }
}
