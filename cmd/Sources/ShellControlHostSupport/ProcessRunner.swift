import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, CustomStringConvertible, Sendable {
    case failed(String, Int32, String)
    case outputTooLarge
    case timedOut(String)

    public var description: String {
        switch self {
        case .failed(let command, let status, let detail): "\(command) failed (\(status)): \(detail)"
        case .outputTooLarge: "helper output exceeded its limit"
        case .timedOut(let command): "helper timed out: \(command)"
        }
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult
}

/// Continuously drains one helper pipe. Data beyond the bound is discarded so
/// a noisy helper can never block forever on a full pipe. The unchecked marker
/// is confined to this lock-protected file-descriptor owner.
private final class BoundedPipeDrain: @unchecked Sendable {
    private let handle: FileHandle
    private let limit: Int
    private let condition = NSCondition()
    private var bytes = Data()
    private var overflowed = false
    private var ended = false

    init(_ handle: FileHandle, limit: Int) { self.handle = handle; self.limit = limit }

    func start() {
        handle.readabilityHandler = { [self] readable in
            let chunk = readable.availableData
            if chunk.isEmpty {
                condition.lock(); ended = true; condition.broadcast(); condition.unlock()
                readable.readabilityHandler = nil
                return
            }
            ingest(chunk)
        }
    }

    private func ingest(_ chunk: Data) {
        condition.lock(); defer { condition.unlock() }
        let remaining = max(0, limit - bytes.count)
        if remaining > 0 { bytes.append(chunk.prefix(remaining)) }
        if chunk.count > remaining { overflowed = true }
    }

    var didOverflow: Bool {
        condition.lock(); defer { condition.unlock() }
        return overflowed
    }

    /// Called only after the child has exited. Wait for the readability queue
    /// to observe EOF before taking ownership away from its handler.
    func finish() throws -> Data {
        condition.lock()
        let deadline = Date().addingTimeInterval(2)
        while !ended && condition.wait(until: deadline) {}
        let complete = ended, tooLarge = overflowed, result = bytes
        condition.unlock()
        handle.readabilityHandler = nil
        try? handle.close()
        guard complete else { throw ProcessRunnerError.outputTooLarge }
        if tooLarge { throw ProcessRunnerError.outputTooLarge }
        return result
    }
}

/// Owns and reaps only helpers it starts. Managed service processes never pass
/// through this type.
public actor ProcessRunner: ProcessRunning {
    public let outputLimit: Int
    public init(outputLimit: Int = 1_048_576) { self.outputLimit = outputLimit }

    public func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let stdoutDrain = BoundedPipeDrain(output.fileHandleForReading, limit: outputLimit)
        let stderrDrain = BoundedPipeDrain(errors.fileHandleForReading, limit: outputLimit)
        stdoutDrain.start(); stderrDrain.start()
        do { try process.run() }
        catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
            throw error
        }

        do {
            try await withTaskCancellationHandler {
                let deadline = ContinuousClock.now + .seconds(timeout)
                while process.isRunning {
                    try Task.checkCancellation()
                    if stdoutDrain.didOverflow || stderrDrain.didOverflow { throw ProcessRunnerError.outputTooLarge }
                    if ContinuousClock.now >= deadline { throw ProcessRunnerError.timedOut(executable) }
                    try await Task.sleep(for: .milliseconds(20))
                }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
        } catch {
            Self.terminateAndReap(process)
            _ = try? stdoutDrain.finish(); _ = try? stderrDrain.finish()
            throw error
        }

        process.waitUntilExit()
        var stdout = Data(), stderr = Data(), drainError: Error?
        do { stdout = try stdoutDrain.finish() } catch { drainError = error }
        do { stderr = try stderrDrain.finish() } catch { if drainError == nil { drainError = error } }
        if let drainError { throw drainError }
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private nonisolated static func terminateAndReap(_ process: Process) {
        if process.isRunning { process.terminate() }
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        #if canImport(Darwin)
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        #endif
        process.waitUntilExit()
    }

    public func checked(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> ProcessResult {
        let result = try await run(executable, arguments, timeout: timeout)
        guard result.status == 0 else {
            let detail = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessRunnerError.failed("\(executable) \(arguments.joined(separator: " "))", result.status, detail)
        }
        return result
    }
}
