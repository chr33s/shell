import Foundation

/// Batches output chunks on a serial queue and emits them at a bounded cadence.
/// The emit callback is called directly on the batcher's background queue - NOT MainActor.
/// Callers must ensure thread-safe handling of emitted data.
nonisolated final class OutputBatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.chr33s.shell.output.batcher", qos: .userInitiated)
    private let minBatchInterval: DispatchTimeInterval
    private let maxBatchInterval: DispatchTimeInterval
    private let emit: @Sendable (Data) -> Void

    private var pending = Data()
    private var timer: DispatchSourceTimer?
    private var firstEnqueueTime: DispatchTime?
    private var currentDeadline: DispatchTime?

    init(minBatchIntervalMs: Int, maxBatchIntervalMs: Int, emit: @escaping @Sendable (Data) -> Void) {
        let minMs = max(1, minBatchIntervalMs)
        let maxMs = max(minMs, maxBatchIntervalMs)
        self.minBatchInterval = .milliseconds(minMs)
        self.maxBatchInterval = .milliseconds(maxMs)
        self.emit = emit
    }

    deinit {
        timer?.cancel()
    }

    func enqueue(_ data: Data) {
        queue.async {
            self.pending.append(data)
            if self.firstEnqueueTime == nil {
                self.firstEnqueueTime = .now()
            }
            self.scheduleTimerLocked()
        }
    }

    func flush(completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            self.flushLocked()
            completion?()
        }
    }

    private func scheduleTimerLocked() {
        guard let firstEnqueueTime = firstEnqueueTime else { return }
        let now = DispatchTime.now()
        let minDeadline = now + minBatchInterval
        let maxDeadline = firstEnqueueTime + maxBatchInterval
        let deadline: DispatchTime
        if minDeadline.uptimeNanoseconds <= maxDeadline.uptimeNanoseconds {
            deadline = minDeadline
        } else {
            deadline = maxDeadline
        }

        if let currentDeadline,
           currentDeadline.uptimeNanoseconds == deadline.uptimeNanoseconds {
            return
        }

        cancelTimerLocked()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: deadline)
        timer.setEventHandler { [weak self] in
            self?.flushLocked()
        }
        timer.resume()
        self.timer = timer
        self.currentDeadline = deadline
    }

    private func flushLocked() {
        guard !pending.isEmpty else {
            cancelTimerLocked()
            firstEnqueueTime = nil
            currentDeadline = nil
            return
        }

        let data = pending
        pending.removeAll(keepingCapacity: true)

        cancelTimerLocked()
        firstEnqueueTime = nil
        currentDeadline = nil

        emit(data)
    }

    private func cancelTimerLocked() {
        timer?.cancel()
        timer = nil
    }
}
