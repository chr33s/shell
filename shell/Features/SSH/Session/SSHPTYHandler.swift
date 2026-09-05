//
//  SSHPTYHandler.swift
//  shell
//
//  Custom NIOSSH channel handler for PTY sessions with dynamic window resizing support
//

import Foundation
@preconcurrency import NIOCore
@preconcurrency import NIOSSH

/// Handler for SSH PTY sessions that supports dynamic window resizing
/// Runs on NIO event loop, not MainActor - marked nonisolated and @unchecked Sendable
/// because NIO guarantees single-threaded access on the event loop.
nonisolated final class SSHPTYHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    // MARK: - Properties

    /// Current terminal size
    private var terminalSize: TerminalPTY.TerminalSize

    /// Callback for output data
    /// NOTE: May be called from NIO event loop. Must be thread-safe.
    var onOutput: (@Sendable (String) -> Void)?
    var onOutputData: (@Sendable (Data) -> Void)?

    /// Promise to complete when shell exits
    private var exitPromise: EventLoopPromise<Int>?

    /// Stored context for sending window change requests
    private var storedContext: ChannelHandlerContext?

    /// Whether PTY has been set up
    private var ptySetup = false

    /// Buffer for accumulating partial UTF-8 sequences across packet boundaries
    private var utf8Buffer = Data()

    /// Optional command to execute instead of starting a shell
    /// When set, sends ExecRequest instead of ShellRequest (used for tmux auto-start)
    private let execCommand: String?

    /// TERM to request in the pty-req, already resolved from the connection's
    /// override and the global default.
    private let term: String

    /// Get the effective locale to send to remote servers, or nil if locale forwarding is disabled.
    /// Uses LocaleHelper to extract clean language/region codes without iOS regional modifiers.
    private var effectiveLocale: String? {
        LocaleHelper.effectiveLocale
    }

    // MARK: - Initialization

    init(terminalSize: TerminalPTY.TerminalSize,
         exitPromise: EventLoopPromise<Int>,
         execCommand: String? = nil,
         term: String = TerminalTypeSettings.fallback) {
        self.terminalSize = terminalSize
        self.exitPromise = exitPromise
        self.execCommand = execCommand
        self.term = term
    }

    // MARK: - Handler Lifecycle

    func handlerAdded(context: ChannelHandlerContext) {
        self.storedContext = context

        // Allow remote half closure
        // Capture self (which is @unchecked Sendable) instead of context to satisfy Swift 6
        let setOption = context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true)
        setOption.whenFailure { [self] error in
            // Use stored context - guaranteed to be on same event loop
            self.storedContext?.fireErrorCaught(error)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        // Send PTY request
        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: term,
            terminalCharacterWidth: Int(terminalSize.cols),
            terminalRowHeight: Int(terminalSize.rows),
            terminalPixelWidth: Int(terminalSize.pixelWidth),
            terminalPixelHeight: Int(terminalSize.pixelHeight),
            terminalModes: SSHConnectionHelper.defaultPTYTerminalModes
        )

        context.triggerUserOutboundEvent(ptyRequest, promise: nil)

        // Send environment variables for UTF-8 locale support
        // This allows text editors like vim/nano to properly render emojis and multibyte characters
        // Only set LANG (not LC_ALL) to allow users to customize individual LC_* categories
        if let locale = effectiveLocale {
            let langEnv = SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false,
                name: "LANG",
                value: locale
            )
            context.triggerUserOutboundEvent(langEnv, promise: nil)

            // Send LANGUAGE environment variable for gettext translation priority
            if let preferredLanguages = LocaleHelper.effectivePreferredLanguages {
                let languageEnv = SSHChannelRequestEvent.EnvironmentRequest(
                    wantReply: false,
                    name: "LANGUAGE",
                    value: preferredLanguages
                )
                context.triggerUserOutboundEvent(languageEnv, promise: nil)
            }

            print("🌍 Locale sent to remote: \(locale)")
        }

        // Identify the client to the remote host; dropped silently by servers
        // without AcceptEnv LC_*.
        for envVar in TerminalIdentity.forwardedVariables {
            let identityEnv = SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false,
                name: envVar.name,
                value: envVar.value
            )
            context.triggerUserOutboundEvent(identityEnv, promise: nil)
        }

        // Send shell or exec request
        if let command = execCommand {
            // Execute a specific command (used for tmux auto-start)
            let execRequest = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: false)
            context.triggerUserOutboundEvent(execRequest, promise: nil)
            print("✅ PTY session established with exec command")
        } else {
            // Start interactive shell
            let shellRequest = SSHChannelRequestEvent.ShellRequest(wantReply: false)
            context.triggerUserOutboundEvent(shellRequest, promise: nil)
            print("✅ PTY session established with size \(terminalSize.rows)x\(terminalSize.cols)")
        }

        ptySetup = true
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        if let promise = exitPromise {
            self.exitPromise = nil
            promise.fail(SSHPTYError.sessionClosed)
        }
        storedContext = nil
    }

    deinit {
        // Safety net: If the handler is deallocated with an unfulfilled promise,
        // fail it to prevent NIO crashes. This can happen when authentication fails
        // before the handler is added to the pipeline.
        if let promise = exitPromise {
            self.exitPromise = nil
            promise.fail(SSHPTYError.sessionClosed)
        }
    }

    // MARK: - Promise Management

    /// Explicitly fail the exit promise with a given error
    /// This should be called by SSHSession when cleaning up after errors
    func failExitPromise(with error: Error) {
        if let promise = exitPromise {
            self.exitPromise = nil
            promise.fail(error)
        }
    }

    // MARK: - Inbound (Server → Client)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .byteBuffer(let bytes) = data.data else {
            return
        }

        // Prefer raw bytes when possible to avoid UTF-8 decoding cost on the event loop.
        if let onOutputData = onOutputData,
           let bytesView = bytes.getBytes(at: 0, length: bytes.readableBytes) {
            if !utf8Buffer.isEmpty {
                utf8Buffer.removeAll(keepingCapacity: true)
            }
            onOutputData(Data(bytesView))
            return
        }

        // Append new bytes to buffer
        if let bytesView = bytes.getBytes(at: 0, length: bytes.readableBytes) {
            utf8Buffer.append(contentsOf: bytesView)
        }

        // Decode complete UTF-8 sequences
        var decoded = ""
        var validByteCount = 0
        var utf8Decoder = UTF8()
        var iterator = utf8Buffer.makeIterator()

        decodeLoop: while true {
            switch utf8Decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                // Successfully decoded a Unicode scalar
                decoded.append(Character(scalar))
                validByteCount = utf8Buffer.count - IteratorSequence(iterator).underestimatedCount

            case .emptyInput:
                // No more complete sequences available
                break decodeLoop

            case .error:
                // Invalid UTF-8 sequence - skip one byte and continue
                // This handles corrupted data gracefully
                if validByteCount < utf8Buffer.count {
                    validByteCount += 1
                    // Reset decoder and continue from next byte
                    let newIterator = utf8Buffer.dropFirst(validByteCount).makeIterator()
                    iterator = newIterator
                    utf8Decoder = UTF8()
                } else {
                    break decodeLoop
                }
            }
        }

        // Forward decoded output if we have any
        if !decoded.isEmpty {
            onOutput?(decoded)
        }

        // Keep only the incomplete UTF-8 sequence bytes for the next packet
        if validByteCount > 0 {
            utf8Buffer = Data(utf8Buffer.dropFirst(validByteCount))
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as SSHChannelRequestEvent.ExitStatus:
            if let promise = self.exitPromise {
                self.exitPromise = nil
                promise.succeed(event.exitStatus)
            }

        case let event as ChannelEvent:
            switch event {
            case .inputClosed, .outputClosed:
                // Channel is closing
                break
            }

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    // MARK: - Outbound (Client → Server)

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }

    // MARK: - Window Resize

    /// Sends a window change request to the SSH server
    func sendWindowChange(newSize: TerminalPTY.TerminalSize) {
        guard let context = storedContext, ptySetup else {
            print("⚠️ Cannot send window change: PTY not ready")
            return
        }

        terminalSize = newSize

        let windowChangeRequest = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: Int(newSize.cols),
            terminalRowHeight: Int(newSize.rows),
            terminalPixelWidth: Int(newSize.pixelWidth),
            terminalPixelHeight: Int(newSize.pixelHeight)
        )

        // Must execute on the channel's event loop
        // Capture self (which is @unchecked Sendable) instead of context to satisfy Swift 6
        context.eventLoop.execute { [self] in
            self.storedContext?.triggerUserOutboundEvent(windowChangeRequest, promise: nil)
        }
    }
}

// MARK: - Errors

enum SSHPTYError: Error {
    case sessionClosed
    case channelCreationFailed
}
