import Darwin
import Dispatch

/// The pipe pair behind `use_external_io`: the host writes program output to
/// `inputFD` (Swiftty's "slave fd"), and reads replies and encoded input from
/// `responseFD`. Both ends are owned here and closed on `close()`.
final class ExternalIO: @unchecked Sendable {
    let inputFD: Int32 // write end, handed to the host
    let responseFD: Int32 // read end, handed to the host
    private let inputRead: Int32
    private let responseWrite: Int32
    private let queue = DispatchQueue(label: "swiftty.runtime.io", qos: .userInteractive)
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    private var pending: [UInt8] = []
    private let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 64 * 1024, alignment: 16)
    private var closed = false

    /// Reply backlog beyond which the oldest bytes are dropped (a host that
    /// stopped reading must not grow memory without bound).
    static let maxPending = 4 << 20

    init?(onOutput: @escaping @Sendable ([UInt8]) -> Void) {
        var input: [Int32] = [-1, -1], response: [Int32] = [-1, -1]
        guard pipe(&input) == 0 else { return nil }
        guard pipe(&response) == 0 else {
            Darwin.close(input[0]); Darwin.close(input[1])
            return nil
        }
        inputRead = input[0]
        inputFD = input[1]
        responseFD = response[0]
        responseWrite = response[1]
        for fd in [inputRead, inputFD, responseFD, responseWrite] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        _ = fcntl(inputRead, F_SETFL, fcntl(inputRead, F_GETFL) | O_NONBLOCK)
        _ = fcntl(responseWrite, F_SETFL, fcntl(responseWrite, F_GETFL) | O_NONBLOCK)

        let read = DispatchSource.makeReadSource(fileDescriptor: inputRead, queue: queue)
        read.setEventHandler { [unowned self] in
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
                }
                break
            }
        }
        let inputRead = inputRead, responseWrite = responseWrite
        read.setCancelHandler { Darwin.close(inputRead) }
        read.resume()
        readSource = read
        let write = DispatchSource.makeWriteSource(fileDescriptor: responseWrite, queue: queue)
        write.setEventHandler { [unowned self] in flush() }
        write.setCancelHandler { Darwin.close(responseWrite) }
        writeSource = write
    }

    deinit {
        buffer.deallocate()
    }

    /// Queues bytes for the host's response reader.
    func write(_ bytes: [UInt8]) {
        queue.async { [self] in
            guard !closed else { return }
            pending.append(contentsOf: bytes)
            if pending.count > Self.maxPending {
                pending.removeFirst(pending.count - Self.maxPending)
            }
            flush()
        }
    }

    private func flush() {
        while !pending.isEmpty {
            let n = pending.withUnsafeBytes { Darwin.write(responseWrite, $0.baseAddress, $0.count) }
            if n > 0 {
                pending.removeFirst(n)
                continue
            }
            if n < 0, errno == EINTR {
                continue
            }
            break // EAGAIN (or the reader closed): wait for writability
        }
        setWriteSourceActive(!pending.isEmpty)
    }

    private func setWriteSourceActive(_ active: Bool) {
        guard let writeSource, active != writeSourceActive else { return }
        writeSourceActive = active
        if active {
            writeSource.resume()
        } else {
            writeSource.suspend()
        }
    }

    func close() {
        queue.sync {
            guard !closed else { return }
            closed = true
            readSource?.cancel()
            readSource = nil
            setWriteSourceActive(true) // a suspended source must not be released
            writeSource?.cancel()
            writeSource = nil
            pending = []
            // Our ends close in the sources' cancel handlers.
            Darwin.close(inputFD)
            Darwin.close(responseFD)
        }
    }
}
