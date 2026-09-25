//
//  main.swift
//  ShellControlHost
//
//  The bundled, sandboxed Control host: a background-only app-like wrapper
//  registered by the Catalyst app as a per-user LaunchAgent through
//  SMAppService, with launchd as its only supervisor
//  (docs/specs/agent-relay.md sections 2.1, 18.2, and 18.3).
//
//  It composes the broker and daemon libraries in one process, publishes the
//  owned UI's XPC service, and otherwise sleeps in dispatchMain: every idle
//  wake-up is an event (a connection, a signal, a timer the daemon owns),
//  never a polling loop (spec A50).
//

import Foundation
import os
import ShellControlHostRuntime
import XPC

/// Development flags, for running the binary outside launchd:
///   --storage-dir /absolute/dir   keep all state under one directory
///   --port N                      broker port (default: persisted, 8443)
///   --no-xpc                      do not publish the Mach service
/// launchd passes none of them; in the sandbox an arbitrary storage path is
/// denied anyway, so they grant nothing.
struct HostOptions {
    var storageDirectory: URL?
    var port: UInt16?
    var publishXPC = true

    static func parse(_ arguments: [String]) -> HostOptions {
        var options = HostOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--storage-dir" where index + 1 < arguments.count && arguments[index + 1].hasPrefix("/"):
                options.storageDirectory = URL(fileURLWithPath: arguments[index + 1])
                index += 1
            case "--port" where index + 1 < arguments.count:
                options.port = UInt16(arguments[index + 1])
                index += 1
            case "--no-xpc":
                options.publishXPC = false
            default:
                HostMain.log("ignoring argument \(arguments[index])")
            }
            index += 1
        }
        return options
    }
}

enum HostMain {
    static let logger = Logger(subsystem: ControlHostWire.hostBundleIdentifier, category: "host")
    /// Launched by launchd for this job, rather than by hand.
    static let isLaunchdJob = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == ControlHostWire.launchAgentLabel

    nonisolated(unsafe) static var listener: XPCListener?
    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []

    static func log(_ message: String) {
        logger.log("\(message, privacy: .public)")
        if !isLaunchdJob {
            FileHandle.standardError.write(Data("ShellControlHost: \(message)\n".utf8))
        }
    }

    /// Exits after a pause, so launchd's `KeepAlive` restart cannot become a
    /// tight crash loop (spec 19.3).
    static func exitAfterBackoff(_ code: Int32) -> Never {
        if isLaunchdJob { sleep(30) }
        exit(code)
    }

    static func run(_ options: HostOptions) async {
        let layout: HostStorageLayout
        if let storageDirectory = options.storageDirectory {
            layout = HostStorageLayout(developmentRoot: storageDirectory)
        } else {
            do {
                layout = try HostStorageLayout.resolve()
            } catch {
                log("cannot resolve host storage: \(error)")
                exitAfterBackoff(EX_CONFIG)
            }
        }
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development"
        let runtime = HostRuntime(configuration: HostRuntime.Configuration(
            layout: layout,
            hostBuild: build,
            brokerPortOverride: options.port,
            log: { log($0) }
        ))
        do {
            try await runtime.acquireOwnership()
        } catch {
            // A duplicate never serves: the first instance owns the ledger.
            log("refusing to start: \(error)")
            exitAfterBackoff(EX_TEMPFAIL)
        }

        installSignalHandlers(runtime)

        if options.publishXPC {
            let service = HostXPCService(runtime: runtime, authorizer: CodeSigningPeerAuthorizer.shellApp, log: { log($0) })
            do {
                listener = try service.listen(
                    requirement: .isFromSameTeam(andMatchesSigningIdentifier: ControlHostWire.appBundleIdentifier)
                )
            } catch {
                // The host still serves adapters; the UI reports it unreachable.
                log("cannot publish \(ControlHostWire.machServiceName): \(error)")
            }
        }

        do {
            try await runtime.start()
        } catch {
            log("start failed: \(error)")
            exitAfterBackoff(EX_SOFTWARE)
        }
        let status = await runtime.status()
        log("host \(build) is \(status.phase.rawValue)\(status.detail.map { ": \($0)" } ?? "")")
    }

    static func installSignalHandlers(_ runtime: HostRuntime) {
        signal(SIGPIPE, SIG_IGN)
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                Task {
                    log("stopping on signal \(number)")
                    listener?.cancel()
                    await runtime.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }
}

let options = HostOptions.parse(Array(CommandLine.arguments.dropFirst()))
Task { await HostMain.run(options) }
dispatchMain()
