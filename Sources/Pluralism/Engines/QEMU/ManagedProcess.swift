import Darwin
import Foundation
import PluralismCore

/// Ein Hintergrundprozess (QEMU oder swtpm), dessen Ausgabe in eine Logdatei läuft.
///
/// Nebenläufigkeit: Alle gespeicherten Eigenschaften werden im Initialisierer gesetzt und danach
/// nicht mehr geändert. `Process` und `FileHandle` sind für Zugriffe aus mehreren Threads gedacht.
/// Der Rückruf `onExit` gehört dem Main Actor.
final class ManagedProcess: @unchecked Sendable {
    let plan: ProcessPlan
    private let process = Process()
    private let logHandle: FileHandle?
    /// Wird auf dem Main Actor mit dem Exit-Status aufgerufen.
    @MainActor var onExit: ((Int32) -> Void)?

    init(plan: ProcessPlan, logURL: URL) throws {
        self.plan = plan
        let fm = FileManager.default
        try fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logURL.path) {
            fm.createFile(atPath: logURL.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: logURL)
        _ = try? handle?.seekToEnd()
        logHandle = handle

        process.executableURL = URL(fileURLWithPath: plan.executable)
        process.arguments = plan.arguments
        if let handle {
            process.standardOutput = handle
            process.standardError = handle
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            MainQueue.async {
                self?.onExit?(status)
            }
        }
    }

    func launch() throws {
        let stamp = ISO8601DateFormatter().string(from: Date())
        if let data = "\n[\(stamp)] \(plan.commandLine)\n".data(using: .utf8) {
            try? logHandle?.write(contentsOf: data)
        }
        try process.run()
    }

    var isRunning: Bool { process.isRunning }

    var processIdentifier: Int32 { process.processIdentifier }

    /// SIGTERM. QEMU beendet sich dann sauber (wie "quit").
    func terminate() {
        if process.isRunning {
            process.terminate()
        }
    }

    /// SIGKILL, falls ein Prozess hängt.
    func kill() {
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    deinit {
        try? logHandle?.close()
    }
}

/// Kurze Befehle synchron ausführen (diskutil, hdiutil, qemu-img, qemu -version).
enum ShellCommand {
    struct Result {
        var status: Int32
        var output: String
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 600) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let timer = DispatchWorkItem { [weak process] in
            if let process, process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// Wie `run`, wirft aber bei Exit-Status ungleich 0.
    @discardableResult
    static func runChecked(_ executable: String, _ arguments: [String], timeout: TimeInterval = 600) throws -> String {
        let result = try run(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw PluralismError.message("\(name) ist fehlgeschlagen (Status \(result.status)): \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result.output
    }
}
