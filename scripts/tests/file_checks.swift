import CAndroidMTP
import Foundation

@main
struct FileChecks {
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw AndroidMTPError.message("Check failed: \(message)") }
    }

    static func rejects(_ message: String, _ operation: () throws -> Void) throws {
        do { try operation() }
        catch { return }
        throw AndroidMTPError.message("Check failed: expected rejection for \(message)")
    }

    static func main() async throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent("AndroidMTP-checks-\(UUID().uuidString)")
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }

        for name in ["", ".", "..", "../escape", "/absolute", "folder/file", "bad\0name"] {
            try rejects("unsafe name \(name)") { try FileSafety.validateName(name) }
        }
        for name in ["照片.jpg", "résumé.pdf", "emoji-📱.txt", "a\\b", "report final.txt"] {
            try FileSafety.validateName(name)
            let destination = try FileSafety.destination(directory: temporary, name: name)
            try require(destination.deletingLastPathComponent().path == temporary.resolvingSymlinksInPath().standardizedFileURL.path, "destination must stay in selected folder")
        }
        try require(FileSafety.collisionKey("Résumé") == FileSafety.collisionKey("RE\u{301}SUME\u{301}"), "canonical and case collisions")
        let existing = temporary.appendingPathComponent("existing.txt")
        try Data("original".utf8).write(to: existing)
        try rejects("existing destination") { _ = try FileSafety.destination(directory: temporary, name: existing.lastPathComponent) }
        let dangling = temporary.appendingPathComponent("dangling.txt")
        try manager.createSymbolicLink(at: dangling, withDestinationURL: temporary.appendingPathComponent("missing"))
        try rejects("dangling symlink destination") { _ = try FileSafety.destination(directory: temporary, name: dangling.lastPathComponent) }
        try rejects("remote URL") { _ = try FileSafety.destination(directory: URL(string: "https://example.com")!, name: "x") }
        try rejects("missing parent") { _ = try FileSafety.destination(directory: temporary.appendingPathComponent("absent"), name: "x") }

        let payload = temporary.appendingPathComponent("payload")
        try Data("new".utf8).write(to: payload)
        var cError: UnsafeMutablePointer<CChar>?
        let collisionResult = amtp_move_no_replace(payload.path, existing.path, &cError)
        if let cError { amtp_free_error(cError) }
        try require(collisionResult != 0, "atomic commit must reject existing files")
        try require(try Data(contentsOf: existing) == Data("original".utf8), "existing contents preserved")
        try require(manager.fileExists(atPath: payload.path), "failed commit preserves staged payload")
        let committed = temporary.appendingPathComponent("completed.txt")
        cError = nil
        let moveResult = amtp_move_no_replace(payload.path, committed.path, &cError)
        if let cError { amtp_free_error(cError) }
        try require(moveResult == 0, "atomic commit into new destination")
        try require(try Data(contentsOf: committed) == Data("new".utf8), "committed contents")

        let cancellation = amtp_cancellation_create()!
        defer { amtp_cancellation_free(cancellation) }
        try require(amtp_cancellation_is_cancelled(cancellation) == 0, "new cancellation state")
        amtp_cancellation_cancel(cancellation)
        try require(amtp_cancellation_is_cancelled(cancellation) != 0, "cancellation signal")
        amtp_cancellation_reset(cancellation)
        try require(amtp_cancellation_is_cancelled(cancellation) == 0, "reset cancellation signal")
        try require(TransferUpdate(completed: 8_000_000_000, total: 16_000_000_000).fraction == 0.5, "64-bit file progress")
        try require(TransferUpdate(completed: 200, total: 100).fraction == 1, "progress clamped")
        try require(TransferUpdate(completed: 0, total: 0).fraction == 0, "empty progress avoids division by zero")

        let service = MTPService()
        // These only exercise disconnected preflight; they never scan or open USB devices.
        do {
            _ = try await service.list(storageID: 1, parentID: UInt32.max)
            throw AndroidMTPError.message("Check failed: disconnected list should fail")
        } catch AndroidMTPError.message(let message) {
            try require(message == "Connect an Android device first.", "disconnected request error")
        }
        await service.disconnect()
        print("File safety, atomic commit, cancellation, 64-bit progress, and disconnected-service checks passed.")
    }
}
