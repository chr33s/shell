//===----------------------------------------------------------------------===//
//
// Protocol-level tracing for NIOSSH. Emits human-readable summaries of every
// inbound/outbound SSH message and every transport state transition through
// `NIOSSHDebug.shared.event(...)`.
//
// Designed for diagnosing handshake stalls (e.g. servers that wait for our
// NEWKEYS forever, peers that send unexpected message orderings, signature
// verification failures). Off by default; cost when no event handler is set
// is one method-pointer load + nil compare per message.
//
// ─── SECURITY ───────────────────────────────────────────────────────────────
// NEVER LOG: passwords, private key bytes, key passphrases, raw public-key
// bytes, signature bytes, shared secrets, ephemeral KEX private keys.
// SAFE: hostnames, ports, usernames, public-key algorithm prefixes
// (e.g. "ssh-ed25519"), algorithm names, message types and sizes,
// channel ids, banner text (truncated), service names, error descriptions.
//
//===----------------------------------------------------------------------===//

import NIOCore

enum NIOSSHTrace {
    /// Cap for any free-form server-supplied text we include in a trace line.
    static let maxTextLen = 256

    /// Truncate any server-supplied string to keep trace lines bounded.
    static func truncate(_ text: String, max: Int = maxTextLen) -> String {
        if text.count <= max { return text }
        let prefix = text.prefix(max)
        return "\(prefix)…[+\(text.count - max)]"
    }

    /// Compact comma-joined algorithm list. Caps very long lists.
    static func joinAlgs(_ algs: [Substring], cap: Int = 8) -> String {
        if algs.count <= cap {
            return algs.joined(separator: ",")
        }
        let head = algs.prefix(cap).joined(separator: ",")
        return "\(head),…(+\(algs.count - cap))"
    }

    /// Trace an inbound message in the given transport state. No-op when no
    /// event handler is wired or the message is high-frequency (channelData,
    /// channelExtendedData, channelWindowAdjust — those have dedicated counters).
    ///
    /// Fast-path: when no event handler is wired, the only work done is one
    /// atomic-load of `isEventEnabled` plus a branch. The expensive
    /// `traceSummary` string formatting runs only when the trace is actually
    /// being delivered.
    @inline(__always)
    static func inbound(_ message: SSHMessage, state: @autoclosure () -> String) {
        guard NIOSSHDebug.shared.isEventEnabled else { return }
        if message.isHighFrequencyForTrace { return }
        NIOSSHDebug.shared.event("IN  [\(state())] \(message.traceSummary)")
    }

    /// Trace an outbound message in the given transport state.
    @inline(__always)
    static func outbound(_ message: SSHMessage, state: @autoclosure () -> String) {
        guard NIOSSHDebug.shared.isEventEnabled else { return }
        if message.isHighFrequencyForTrace { return }
        NIOSSHDebug.shared.event("OUT [\(state())] \(message.traceSummary)")
    }

    /// Trace a transport-state transition.
    @inline(__always)
    static func stateTransition(from: @autoclosure () -> String, to: @autoclosure () -> String, reason: @autoclosure () -> String = "") {
        guard NIOSSHDebug.shared.isEventEnabled else { return }
        let r = reason()
        if r.isEmpty {
            NIOSSHDebug.shared.event("STATE \(from()) → \(to())")
        } else {
            NIOSSHDebug.shared.event("STATE \(from()) → \(to()) (\(r))")
        }
    }

    /// Trace an error from inside the state machine (e.g. signature
    /// verification failure, KEX algorithm negotiation failure). Errors
    /// already throw to the caller; this gives a separate breadcrumb in
    /// the trace stream so we can correlate it with the surrounding messages.
    @inline(__always)
    static func error(_ where_: @autoclosure () -> String, _ error: @autoclosure () -> Error) {
        guard NIOSSHDebug.shared.isEventEnabled else { return }
        NIOSSHDebug.shared.event("ERROR [\(where_())] \(error())")
    }

    /// Free-form trace event. Used for KEX milestones (signature verified,
    /// keys derived) where no SSHMessage is in scope.
    @inline(__always)
    static func event(_ message: @autoclosure () -> String) {
        guard NIOSSHDebug.shared.isEventEnabled else { return }
        NIOSSHDebug.shared.event(message())
    }
}

// MARK: - SSHMessage Summary

/// Convenience for trace summaries — `keyPrefix` returns a `String.UTF8View`,
/// not a `String`, so we materialize it once here.
extension NIOSSHPublicKey {
    var keyPrefixString: String { String(decoding: self.keyPrefix, as: UTF8.self) }
}

extension SSHMessage {
    /// Whether this message arrives at high frequency (per-byte data plane);
    /// suppressed from per-message tracing because the existing increment
    /// counters in NIOSSHHandler/SSHChannelMultiplexer already cover them.
    var isHighFrequencyForTrace: Bool {
        switch self {
        case .channelData, .channelExtendedData, .channelWindowAdjust:
            return true
        default:
            return false
        }
    }

    /// Safe (no-key-material) summary suitable for protocol-level traces.
    /// Mirrors the level of detail OpenSSH's `ssh -vv` produces.
    var traceSummary: String {
        switch self {
        case .version(let v):
            return "VERSION \"\(NIOSSHTrace.truncate(v))\""

        case .disconnect(let m):
            return "DISCONNECT reason=\(m.reason) desc=\"\(NIOSSHTrace.truncate(m.description))\""

        case .ignore(let m):
            return "IGNORE bytes=\(m.data.readableBytes)"

        case .unimplemented(let u):
            return "UNIMPLEMENTED seq=\(u.sequenceNumber)"

        case .debug(let m):
            return "DEBUG alwaysDisplay=\(m.alwaysDisplay) message=\"\(NIOSSHTrace.truncate(m.message))\""

        case .serviceRequest(let r):
            return "SERVICE_REQUEST service=\(r.service)"

        case .serviceAccept(let r):
            return "SERVICE_ACCEPT service=\(r.service)"

        case .extensionInfo(let message):
            return "EXT_INFO extensions=\(message.extensions.count)"

        case .keyExchange(let m):
            return "KEXINIT" +
                " kex=[\(NIOSSHTrace.joinAlgs(m.keyExchangeAlgorithms))]" +
                " hostKey=[\(NIOSSHTrace.joinAlgs(m.serverHostKeyAlgorithms))]" +
                " encCS=[\(NIOSSHTrace.joinAlgs(m.encryptionAlgorithmsClientToServer))]" +
                " encSC=[\(NIOSSHTrace.joinAlgs(m.encryptionAlgorithmsServerToClient))]" +
                " macCS=[\(NIOSSHTrace.joinAlgs(m.macAlgorithmsClientToServer))]" +
                " macSC=[\(NIOSSHTrace.joinAlgs(m.macAlgorithmsServerToClient))]" +
                " compCS=[\(NIOSSHTrace.joinAlgs(m.compressionAlgorithmsClientToServer))]" +
                " compSC=[\(NIOSSHTrace.joinAlgs(m.compressionAlgorithmsServerToClient))]" +
                " firstKexFollows=\(m.firstKexPacketFollows)"

        case .keyExchangeInit(let m):
            // Q_C — client ephemeral public key bytes; size is safe to log.
            return "KEX_ECDH_INIT clientPubKeyBytes=\(m.publicKey.readableBytes)"

        case .keyExchangeReply(let m):
            // Server host-key algorithm prefix is wire-public; size of Q_S
            // and signature are also safe. Bytes themselves are NOT logged.
            return "KEX_ECDH_REPLY hostKeyType=\(m.hostKey.keyPrefixString)" +
                " serverPubKeyBytes=\(m.publicKey.readableBytes) sig=present"

        case .newKeys:
            return "NEWKEYS"

        case .userAuthRequest(let m):
            let methodStr: String
            switch m.method {
            case .none:
                methodStr = "none"
            case .password:
                // Length not logged — would leak password length.
                methodStr = "password"
            case .publicKey(let pk):
                switch pk {
                case .known(let key, let signature):
                    methodStr = "publickey type=\(key.keyPrefixString) sig=\(signature == nil ? "absent" : "present")"
                case .unknown:
                    methodStr = "publickey type=unknown"
                }
            case .keyboardInteractive:
                methodStr = "keyboard-interactive"
            }
            return "USERAUTH_REQUEST user=\(m.username) service=\(m.service) method=\(methodStr)"

        case .userAuthFailure(let m):
            return "USERAUTH_FAILURE allowed=[\(m.authentications.joined(separator: ","))] partial=\(m.partialSuccess)"

        case .userAuthSuccess:
            return "USERAUTH_SUCCESS"

        case .userAuthBanner(let m):
            return "USERAUTH_BANNER lang=\(m.languageTag.isEmpty ? "-" : m.languageTag) message=\"\(NIOSSHTrace.truncate(m.message))\""

        case .userAuthPKOK(let m):
            return "USERAUTH_PK_OK type=\(m.key.keyPrefixString)"

        case .userAuthInfoRequest(let m):
            return "USERAUTH_INFO_REQUEST name=\"\(NIOSSHTrace.truncate(m.name))\" prompts=\(m.prompts.count)"

        case .userAuthInfoResponse(let m):
            // Never log response values — they carry passwords/OTP codes.
            return "USERAUTH_INFO_RESPONSE responses=\(m.responses.count)"

        case .globalRequest(let m):
            let typeStr: String
            switch m.type {
            case .tcpipForward(let host, let port):
                typeStr = "tcpip-forward host=\(host) port=\(port)"
            case .cancelTcpipForward(let host, let port):
                typeStr = "cancel-tcpip-forward host=\(host) port=\(port)"
            case .unknown(let name, let buf):
                typeStr = "unknown(\(name)) bytes=\(buf.readableBytes)"
            }
            return "GLOBAL_REQUEST \(typeStr) wantReply=\(m.wantReply)"

        case .requestSuccess(let m):
            return "REQUEST_SUCCESS bytes=\(m.buffer.readableBytes)"

        case .requestFailure:
            return "REQUEST_FAILURE"

        case .channelOpen(let m):
            let typeStr: String
            switch m.type {
            case .session: typeStr = "session"
            case .forwardedTCPIP(let f): typeStr = "forwarded-tcpip listen=\(f.hostListening):\(f.portListening)"
            case .directTCPIP(let d): typeStr = "direct-tcpip dest=\(d.hostToConnectTo):\(d.portToConnectTo)"
            case .authAgent: typeStr = "auth-agent@openssh.com"
            case .forwardedStreamLocal(let f): typeStr = "forwarded-streamlocal socket=\(f.socketPath)"
            case .directStreamLocal(let d): typeStr = "direct-streamlocal socket=\(d.socketPath)"
            }
            return "CHANNEL_OPEN type=\(typeStr) sender=\(m.senderChannel) initialWindow=\(m.initialWindowSize) maxPacket=\(m.maximumPacketSize)"

        case .channelOpenConfirmation(let m):
            return "CHANNEL_OPEN_CONFIRMATION recipient=\(m.recipientChannel) sender=\(m.senderChannel) initialWindow=\(m.initialWindowSize) maxPacket=\(m.maximumPacketSize)"

        case .channelOpenFailure(let m):
            return "CHANNEL_OPEN_FAILURE recipient=\(m.recipientChannel) reason=\(m.reasonCode) desc=\"\(NIOSSHTrace.truncate(m.description))\""

        case .channelWindowAdjust(let m):
            return "CHANNEL_WINDOW_ADJUST channel=\(m.recipientChannel) bytesToAdd=\(m.bytesToAdd)"

        case .channelData(let m):
            return "CHANNEL_DATA channel=\(m.recipientChannel) bytes=\(m.data.readableBytes)"

        case .channelExtendedData(let m):
            return "CHANNEL_EXTENDED_DATA channel=\(m.recipientChannel) typeCode=\(m.dataTypeCode.rawValue) bytes=\(m.data.readableBytes)"

        case .channelEOF(let m):
            return "CHANNEL_EOF channel=\(m.recipientChannel)"

        case .channelClose(let m):
            return "CHANNEL_CLOSE channel=\(m.recipientChannel)"

        case .channelRequest(let m):
            let typeStr: String
            switch m.type {
            case .env(let k, let v):
                typeStr = "env \(k)=\"\(NIOSSHTrace.truncate(v, max: 64))\""
            case .exec(let cmd):
                typeStr = "exec \"\(NIOSSHTrace.truncate(cmd))\""
            case .exitStatus(let s):
                typeStr = "exit-status=\(s)"
            case .exitSignal(let sig, let core, _, let lang):
                typeStr = "exit-signal=\(sig) coreDumped=\(core) lang=\(lang)"
            case .ptyReq(let p):
                typeStr = "pty-req TERM=\(p.termVariable) cols=\(p.characterWidth) rows=\(p.rowHeight)"
            case .shell:
                typeStr = "shell"
            case .subsystem(let s):
                typeStr = "subsystem \(s)"
            case .windowChange(let w):
                typeStr = "window-change cols=\(w.characterWidth) rows=\(w.rowHeight)"
            case .xonXoff(let on):
                typeStr = "xon-xoff \(on)"
            case .signal(let s):
                typeStr = "signal=\(s)"
            case .authAgentReq:
                typeStr = "auth-agent-req@openssh.com"
            case .unknown:
                typeStr = "unknown"
            }
            return "CHANNEL_REQUEST channel=\(m.recipientChannel) \(typeStr) wantReply=\(m.wantReply)"

        case .channelSuccess(let m):
            return "CHANNEL_SUCCESS channel=\(m.recipientChannel)"

        case .channelFailure(let m):
            return "CHANNEL_FAILURE channel=\(m.recipientChannel)"
        }
    }
}
