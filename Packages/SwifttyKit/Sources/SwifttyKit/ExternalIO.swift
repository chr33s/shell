import Darwin
import Dispatch

/// The pipes behind `use_external_io`: the host writes program output to
/// `inputFD` (Swiftty's "slave fd"), reads encoded input from `responseFD`,
/// and terminal-generated replies (DA, DSR, OSC 7501, ...) from `replyFD`,
/// so they never pass for typing. All ends are owned here and closed on
/// `close()`.
final class ExternalIO: @unchecked Sendable {
    let inputFD: Int32 // write end, handed to the host
    let responseFD: Int32 // read end, handed to the host
    let replyFD: Int32 // read end, handed to the host
    private let inputRead: Int32
    private let responseWrite: Int32
    private let replies: OutputPipe
    private let queue = DispatchQueue(label: "swiftty.runtime.io", qos: .userInteractive)
    private var readSource: DispatchSourceRead?
    private let responses: OutputPipe
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)
    private var closed = false

    /// Reply backlog beyond which the oldest bytes are dropped (a host that
    /// stopped reading must not grow memory without bound).
    static let maxPending = 4 << 20

    init?(onOutput: @escaping @Sendable ([UInt8]) -> Void) {
        var input: [Int32] = [-1, -1], response: [Int32] = [-1, -1], reply: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { return nil }
        guard pipe(&response) == 0 else {
            Darwin.close(input[0]); Darwin.close(input[1])
            return nil
        }
        guard pipe(&reply) == 0 else {
            for fd in input + response { Darwin.close(fd) }
            return nil
        }
        inputRead = input[0]
        inputFD = input[1]
        responseFD = response[0]
        responseWrite = response[1]
        replyFD = reply[0]
        for fd in input + response + reply {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        // The host's read ends are non-blocking too: it reads both from
        // dispatch sources, possibly on one serial queue, and a blocking read
        // on one would starve the other.
        for fd in [inputRead, responseFD, replyFD] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
        responses = OutputPipe(fd: response[1], queue: queue)
        replies = OutputPipe(fd: reply[1], queue: queue)

        self.onOutput = onOutput
        let read = DispatchSource.makeReadSource(fileDescriptor: inputRead, queue: queue)
        read.setEventHandler { [unowned self] in drainInput() }
        let inputRead = inputRead
        read.setCancelHandler { Darwin.close(inputRead) }
        read.resume()
        readSource = read
    }

    private let onOutput: @Sendable ([UInt8]) -> Void

    /// Delivers everything readable on the input pipe (on `queue`).
    private func drainInput() {
        guard readSource != nil else { return }
        while true {
            let n = Darwin.read(inputRead, buffer.baseAddress, buffer.count)
            if n > 0 {
                onOutput(Array(UnsafeRawBufferPointer(rebasing: buffer[0 ..< n])))
                continue
            }
            if n < 0, errno == EINTR {
                continue
            }
            if n == 0 {
                readSource?.cancel()
                readSource = nil
            }
            break
        }
    }

    /// Runs `body` after the program output the host already wrote has
    /// been delivered, so it is ordered after that output.
    func afterPendingOutput(_ body: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            if !closed {
                drainInput()
            }
            body()
        }
    }

    deinit {
        buffer.deallocate()
    }

    /// Queues encoded input for the host's response reader.
    func write(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard !closed else { return }
            responses.write(bytes)
        }
    }

    /// Queues a terminal-generated reply for the host's reply reader.
    func writeReply(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard !closed else { return }
            replies.write(bytes)
        }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            readSource?.cancel()
            readSource = nil
            responses.close()
            replies.close()
            // Our ends close in the sources' cancel handlers.
            Darwin.close(inputFD)
            Darwin.close(responseFD)
            Darwin.close(replyFD)
        }
    }
}

/// The write end of a pipe the host reads: non-blocking, with a bounded
/// backlog. Owned by its `ExternalIO`'s queue.
private final class OutputPipe {
    private let fd: Int32
    private let source: DispatchSourceWrite
    private var active = false
    private var pending: [UInt8] = []

    init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [unowned self] in flush() }
        source.setCancelHandler { Darwin.close(fd) }
    }

    func write(_ bytes: [UInt8]) {
        pending.append(contentsOf: bytes)
        if pending.count > ExternalIO.maxPending {
            pending.removeFirst(pending.count - ExternalIO.maxPending)
        }
        flush()
    }

    private func flush() {
        while !pending.isEmpty {
            let n = pending.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
                continue
            }
            if n < 0, errno == EINTR {
                continue
            }
            break // EAGAIN (or the reader closed): wait for writability
        }
        setActive(!pending.isEmpty)
    }

    private func setActive(_ value: Bool) {
        guard value != active else { return }
        active = value
        if value {
            source.resume()
        } else {
            source.suspend()
        }
    }

    func close() {
        setActive(true) // a suspended source must not be released
        source.cancel()
        pending = []
    }
}
