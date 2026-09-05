import Foundation

/// Stateful lone-LF → CRLF normalizer for terminal-bound interpreter output.
/// Idempotent on CRLF input; tracks a trailing CR across chunks. One instance
/// per interpreter output stream.
nonisolated final class LFNormalizer: @unchecked Sendable {
    private let lock = UnfairLock()
    private var previousEndedWithCR = false

    func normalize(_ data: Data) -> Data {
        lock.withLock {
            var out = Data()
            out.reserveCapacity(data.count + (data.count / 16))
            var prevCR = previousEndedWithCR
            for byte in data {
                if byte == 0x0A { // LF
                    if !prevCR { out.append(0x0D) }
                    out.append(0x0A)
                    prevCR = false
                    continue
                }
                out.append(byte)
                prevCR = (byte == 0x0D)
            }
            previousEndedWithCR = prevCR
            return out.count == data.count ? data : out
        }
    }
}

/// Thread-safe output sink for emitting session output from background threads.
nonisolated final class OutputSink: @unchecked Sendable {
    private let lock = UnfairLock()
    private nonisolated(unsafe) var onOutput: (@Sendable (String) -> Void)?
    private nonisolated(unsafe) var onOutputData: (@Sendable (Data) -> Void)?

    nonisolated func update(onOutput: (@Sendable (String) -> Void)?, onOutputData: (@Sendable (Data) -> Void)?) {
        lock.withLock {
            self.onOutput = onOutput
            self.onOutputData = onOutputData
        }
    }

    nonisolated func emit(_ data: Data) {
        let callbacks = lock.withLock { (onOutputData, onOutput) }
        if let onOutputData = callbacks.0 {
            onOutputData(data)
        } else if let onOutput = callbacks.1 {
            onOutput(String(decoding: data, as: UTF8.self))
        }
    }

    nonisolated func emitString(_ output: String) {
        let callbacks = lock.withLock { (onOutputData, onOutput) }
        if let onOutput = callbacks.1 {
            onOutput(output)
        } else if let onOutputData = callbacks.0 {
            onOutputData(Data(output.utf8))
        }
    }
}
