import Foundation
@preconcurrency import ImageCaptureCore

/// Sends standard PTP/MTP transactions through Apple's device service. All native
/// requests must originate on the main run loop, including after session callbacks.
@MainActor
final class SystemPTPLink: NSObject, ICDeviceBrowserDelegate, ICDeviceDelegate {
    private var browser: ICDeviceBrowser?
    private var cameras: [String: ICCameraDevice] = [:]
    private var enumerated = false
    private var scanWaiters: [UUID: CheckedContinuation<[DeviceInfo], Never>] = [:]
    private var failures: [UUID: (Error) -> Void] = [:]
    private var active: ICCameraDevice?
    private var commandInFlight = false
    private var sessionInvalid = false

    func scan() async throws -> [DeviceInfo] {
        if browser == nil {
            let browser = ICDeviceBrowser()
            self.browser = browser
            browser.delegate = self
            browser.browsedDeviceTypeMask = .camera
            browser.start()
        }
        if !cameras.isEmpty { return snapshot() }
        return await withCheckedContinuation { continuation in
            let token = UUID()
            scanWaiters[token] = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, let waiter = self.scanWaiters.removeValue(forKey: token) else { return }
                waiter.resume(returning: self.snapshot())
            }
        }
    }

    func connect(_ device: DeviceInfo) async throws {
        await disconnect()
        _ = try await scan()
        guard let camera = cameras[device.id] else {
            throw AndroidMTPError.message("This phone has disconnected. Scan again and choose the reconnected device.")
        }
        camera.delegate = self
        active = camera
        sessionInvalid = false
        do {
            let _: Void = try await request(timeout: 15, description: "Opening the phone connection") { finish in
                camera.requestOpenSession(options: nil) { error in
                    if let error { finish(.failure(error)) }
                    else { finish(.success(())) }
                }
            }
            guard camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue) else {
                throw AndroidMTPError.message("This device does not support standard MTP commands through macOS.")
            }
        } catch {
            await disconnect()
            throw error
        }
    }

    func disconnect() async {
        let camera = active
        active = nil
        sessionInvalid = false
        failPending(AndroidMTPError.message("The phone connection was closed."))
        guard let camera, camera.hasOpenSession else { return }
        do {
            let _: Void = try await request(timeout: 5, description: "Closing the phone connection") { finish in
                camera.requestCloseSession(options: nil) { error in
                    if let error { finish(.failure(error)) }
                    else { finish(.success(())) }
                }
            }
        } catch {
            // The framework owns the USB handle and releases this client session.
        }
    }

    func transact(code: UInt16, parameters: [UInt32], data: Data?) async throws -> PTPResult {
        guard let camera = active, camera.hasOpenSession, !sessionInvalid else {
            throw AndroidMTPError.message("The phone connection is unavailable. Disconnect and reconnect in File transfer mode.")
        }
        guard !commandInFlight else {
            throw AndroidMTPError.message("Another operation is using this phone. Wait for it to finish.")
        }
        guard (data?.count ?? 0) <= 64 * 1024 * 1024 else {
            throw AndroidMTPError.message("A single device request is too large. Use chunked transfer support.")
        }
        let command = try PTPCodec.command(code: code, parameters: parameters)
        let tracing = ProcessInfo.processInfo.environment["ANDROIDMTP_TRACE"] == "1"
        if tracing {
            let outgoing = data.map { String($0.count) } ?? "none"
            print("MTP request \(String(format: "%04X", code)) params=\(parameters) outgoing=\(outgoing)")
        }
        commandInFlight = true
        defer { commandInFlight = false }
        let response: (Data, Data) = try await request(timeout: 45, description: "Communicating with the phone") { finish in
            camera.requestSendPTPCommand(command, outData: data) { incoming, response, error in
                if let error { finish(.failure(error)) }
                else { finish(.success((incoming, response))) }
            }
        }
        let result = try PTPCodec.response(response.1, data: response.0)
        if tracing {
            print("MTP response \(String(format: "%04X", code)) status=\(String(format: "%04X", result.code)) params=\(result.parameters) incoming=\(result.data.count)")
        }
        return result
    }

    private func request<Value>(timeout: UInt64, description: String,
                                start: (@escaping (Result<Value, Error>) -> Void) -> Void) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let token = UUID()
            failures[token] = { continuation.resume(throwing: $0) }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                guard let self, let fail = self.failures.removeValue(forKey: token) else { return }
                self.sessionInvalid = true
                fail(AndroidMTPError.message("\(description) timed out. Unlock the phone and reconnect it in File transfer mode."))
                self.active?.requestCloseSession(options: nil) { _ in }
            }
            start { [weak self] result in
                Task { @MainActor in
                    guard let self, self.failures.removeValue(forKey: token) != nil else { return }
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func failPending(_ error: Error) {
        let callbacks = Array(failures.values)
        failures.removeAll()
        callbacks.forEach { $0(error) }
    }

    private func snapshot() -> [DeviceInfo] {
        cameras.map { id, camera in
            DeviceInfo(id: id, name: camera.name ?? "Android device",
                       bus: UInt32(truncatingIfNeeded: camera.usbLocationID), address: 0)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func finishScan() {
        let devices = snapshot()
        let waiters = Array(scanWaiters.values)
        scanWaiters.removeAll()
        waiters.forEach { $0.resume(returning: devices) }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        Task { @MainActor in
            guard let camera = device as? ICCameraDevice, camera.usbVendorID != 0,
                  camera.usbVendorID != 0x05ac else { return }
            let identity = camera.uuidString ?? "usb-\(camera.usbVendorID)-\(camera.usbProductID)-\(camera.usbLocationID)"
            self.cameras["system:\(identity)"] = camera
            if !moreComing { self.finishScan() }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        Task { @MainActor in
            self.cameras = self.cameras.filter { $0.value !== device }
            if self.active === device {
                self.active = nil
                self.sessionInvalid = true
                self.failPending(AndroidMTPError.message("The phone disconnected during the operation."))
            }
            if !moreGoing { self.finishScan() }
        }
    }

    nonisolated func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        Task { @MainActor in
            self.enumerated = true
            if !self.cameras.isEmpty { self.finishScan() }
        }
    }

    nonisolated func didRemove(_ device: ICDevice) {
        Task { @MainActor in
            if self.active === device {
                self.active = nil
                self.sessionInvalid = true
                self.failPending(AndroidMTPError.message("The phone disconnected during the operation."))
            }
        }
    }
    nonisolated func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    nonisolated func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        Task { @MainActor in
            guard self.active === device else { return }
            self.sessionInvalid = true
            self.failPending(error ?? AndroidMTPError.message("The phone closed the connection. Reconnect it in File transfer mode."))
        }
    }
}
