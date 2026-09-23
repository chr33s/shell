import Foundation

/// Stateful lone-LF → CRLF normalizer for terminal-bound interpreter output.
/// Idempotent on CRLF input; tracks a trailing CR across chunks. One instance
/// per interpreter output stream.
nonisolated final class LFNormalizer: @unchecked Sendable {
    private let lock = UnfairLock()
    private var previousEndedWithCR = false

    func normalize(_ data: Data) -> Data {
        lock.withLock {
            data.withUnsafeBytes { bytes -> Data in
                let startedWithCR = previousEndedWithCR
                var prevCR = startedWithCR
                var loneLFCount = 0
                for byte in bytes {
                    if byte == 0x0A, !prevCR { loneLFCount += 1 }
                    prevCR = (byte == 0x0D)
                }
                previousEndedWithCR = prevCR
                guard loneLFCount > 0 else { return data }

                var out = Data(count: bytes.count + loneLFCount)
                out.withUnsafeMutableBytes { dst in
                    var j = 0
                    var prev = startedWithCR
                    for byte in bytes {
                        if byte == 0x0A, !prev { // lone LF
                            dst[j] = 0x0D
                            j += 1
                        }
                        dst[j] = byte
                        j += 1
                        prev = (byte == 0x0D)
                    }
                }
                return out
            }
        }
    }
}

/// Thread-safe output sink for emitting session output from background threads.
nonisolated final class OutputSink: @unchecked Sendable {
    private let lock = UnfairLock()
    private var onOutput: (@Sendable (String) -> Void)?
    private var onOutputData: (@Sendable (Data) -> Void)?

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
