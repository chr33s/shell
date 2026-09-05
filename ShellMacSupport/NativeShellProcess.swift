import Foundation
import Darwin

final class NativeShellProcess: NSObject, MacShellProcess {
    let processID: Int32
    private(set) var exitStatus: Int32 = -1
    private let master: Int32
    private var exitSource: DispatchSourceProcess?
    private var exited = false

    init(executable: String, arguments: [String], environment: [String: String],
         directory: String, rows: UInt16, columns: UInt16) throws {
        var argv = ([executable] + arguments).map { strdup($0) } + [nil]
        var envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for entry in argv { free(entry) }
            for entry in envp { free(entry) }
        }
        var descriptor: Int32 = -1
        var pid: pid_t = 0
        let code = shell_spawn_pty(executable, &argv, &envp, directory, rows, columns, &descriptor, &pid)
        guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
        master = descriptor
        processID = pid
        super.init()
    }

    func duplicateMaster() -> Int32 { fcntl(master, F_DUPFD_CLOEXEC, 0) }

    func observeExit(_ completion: @escaping (Int32) -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: processID, eventMask: .exit, queue: .main)
        exitSource = source
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(self.processID, &status, 0) } while result < 0 && errno == EINTR
            self.exited = true
            self.exitStatus = result > 0 ? (status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : -1
            self.exitSource?.cancel()
            self.exitSource = nil
            completion(self.processID)
        }
        source.resume()
    }

    func terminate(signal: Int32) {
        guard !exited else { return }
        let foreground = tcgetpgrp(master)
        if foreground > 0, foreground != processID { kill(-foreground, signal) }
        // The child called setsid(), so it leads its own group and the group
        // signal already reaches it. Only fall back to the bare pid when that
        // group is gone, so a shell that traps the signal sees it once.
        if kill(-processID, signal) != 0 { kill(processID, signal) }
    }

    deinit { close(master) }
}
