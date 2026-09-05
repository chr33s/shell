import Foundation
import NIOSSH
import NIOCore
import NIOFoundationCompat
import Crypto
import os.log

/// Request for user validation of a host key
struct HostKeyValidationRequest: Sendable {
    // Store as UTF-8 data to avoid any string bridging issues
    private let messageData: Data
    let isKeyChanged: Bool

    var message: String {
        // Reconstruct from UTF-8 data
        String(data: messageData, encoding: .utf8) ?? ""
    }

    init(message: String, isKeyChanged: Bool) {
        // Convert to UTF-8 data for safe cross-actor transfer
        self.messageData = message.data(using: .utf8) ?? Data()
        self.isKeyChanged = isKeyChanged
    }
}

/// User's response to host key validation
enum HostKeyValidationResult {
    case accept          // Accept and save to known hosts
    case acceptOnce      // Accept for this session only (don't save)
    case reject          // Reject the connection
}

/// Custom SSH server authentication delegate that validates host keys against known hosts
/// Marked nonisolated and @unchecked Sendable because NIO requires access from any thread.
/// All MainActor interactions are handled internally via Task { @MainActor in ... }.
nonisolated final class SSHHostKeyDelegate: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let hostname: String
    private let port: Int
    private let manager: KnownHostsManager
    private nonisolated(unsafe) let onValidationRequired: (HostKeyValidationRequest) async -> HostKeyValidationResult
    private let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHHostKey")
    private let timeoutCoordinator: SSHTimeoutCoordinator?

    init(
        hostname: String,
        port: Int,
        manager: KnownHostsManager,
        timeoutCoordinator: SSHTimeoutCoordinator? = nil,
        onValidationRequired: @escaping (HostKeyValidationRequest) async -> HostKeyValidationResult
    ) {
        self.hostname = hostname
        self.port = port
        self.manager = manager
        self.timeoutCoordinator = timeoutCoordinator
        self.onValidationRequired = onValidationRequired
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        Task { @MainActor in
            do {
                let result = try await performValidation(hostKey: hostKey)
                if result {
                    validationCompletePromise.succeed(())
                } else {
                    validationCompletePromise.fail(HostKeyRejectedError())
                }
            } catch {
                logger.error("Host key validation failed: \(error.localizedDescription)")
                validationCompletePromise.fail(error)
            }
        }
    }

    /// Request user validation with timeout pause/resume
    @MainActor
    private func requestUserValidation(_ request: HostKeyValidationRequest) async -> HostKeyValidationResult {
        // Pause the handshake timeout while waiting for user
        timeoutCoordinator?.pauseTimeout(remainingTime: SSHTimeoutConfig.handshakeTimeout)

        let result = await onValidationRequired(request)

        // Resume the timeout after user responds
        timeoutCoordinator?.resumeTimeout()

        return result
    }

    @MainActor
    private func performValidation(hostKey: NIOSSHPublicKey) async throws -> Bool {
        // Generate fingerprint and key info
        // Force proper String copies to avoid memory corruption
        let fingerprint = String(generateFingerprint(for: hostKey))
        let keyType = String(getKeyType(from: hostKey))
        let publicKeyData = try serializePublicKey(hostKey)
        let hostnameCopy = String(hostname)
        let portCopy = port

        logger.info("Validating host key for \(hostnameCopy):\(portCopy) - Type: \(keyType), Fingerprint: \(fingerprint)")

        // Check if we have a known host entry
        if let knownHost = manager.getHost(hostname: hostname, port: port) {
            // Compare fingerprints for robustness (survives serialization format changes)
            // Also compare publicKeyData as a fallback for older entries
            let fingerprintsMatch = knownHost.fingerprint == fingerprint
            let publicKeyDataMatches = knownHost.publicKeyData == publicKeyData

            if fingerprintsMatch || publicKeyDataMatches {
                // Key matches - update last seen and accept
                logger.info("Host key matches known host (fingerprint: \(fingerprintsMatch), publicKey: \(publicKeyDataMatches)), accepting")

                // If fingerprints match but publicKeyData differs, update the stored key format
                if fingerprintsMatch && !publicKeyDataMatches {
                    logger.info("Updating stored publicKeyData format for \(hostnameCopy):\(portCopy)")
                    let updatedHost = KnownHost(
                        hostname: hostnameCopy,
                        port: portCopy,
                        publicKeyData: publicKeyData,
                        keyType: keyType,
                        fingerprint: fingerprint,
                        firstSeen: knownHost.firstSeen,
                        lastSeen: Date()
                    )
                    manager.addHost(updatedHost)
                } else {
                    manager.updateLastSeen(hostname: hostname, port: port)
                }
                return true
            } else {
                // Key changed - potential MITM attack!
                logger.warning("Host key changed for \(self.hostname):\(self.port)! Old fingerprint: \(knownHost.fingerprint), New fingerprint: \(fingerprint)")

                // The exact key the user already approved with "Connect Once"
                // this run passes without re-prompting (still not persisted).
                if SessionApprovedHostKeys.shared.matches(hostname: hostnameCopy, port: portCopy, publicKeyData: publicKeyData) {
                    logger.info("Key matches session-approved (Connect Once) key, accepting")
                    return true
                }

                // Build complete message string here, before crossing any boundaries
                let oldFp = String(knownHost.fingerprint)
                let message = "The host key for \(hostnameCopy):\(portCopy) has changed. This could indicate a man-in-the-middle attack!\n\nPreviously Trusted:\n\(oldFp)\n\nNew Key Received:\n\(fingerprint)"

                let request = HostKeyValidationRequest(
                    message: message,
                    isKeyChanged: true
                )

                let result = await requestUserValidation(request)

                switch result {
                case .accept:
                    // User accepted the new key - update known hosts
                    let newHost = KnownHost(
                        hostname: hostnameCopy,
                        port: portCopy,
                        publicKeyData: publicKeyData,
                        keyType: keyType,
                        fingerprint: fingerprint
                    )
                    manager.addHost(newHost)
                    logger.info("User accepted new host key, updated known hosts")
                    return true

                case .acceptOnce:
                    // Accept but don't persist; remember in-memory for
                    // ancillary connections in the same flow.
                    SessionApprovedHostKeys.shared.remember(hostname: hostnameCopy, port: portCopy, publicKeyData: publicKeyData)
                    logger.info("User accepted new host key for this session only")
                    return true

                case .reject:
                    logger.info("User rejected new host key")
                    return false
                }
            }
        } else {
            // New host - prompt user
            logger.info("New host \(self.hostname):\(self.port), requesting user validation")

            if SessionApprovedHostKeys.shared.matches(hostname: hostnameCopy, port: portCopy, publicKeyData: publicKeyData) {
                logger.info("Key matches session-approved (Connect Once) key, accepting")
                return true
            }

            // Build complete message string here, before crossing any boundaries
            let message = "Do you want to trust this host?\n\nHost: \(hostnameCopy):\(portCopy)\nKey Type: \(keyType)\n\nFingerprint:\n\(fingerprint)"

            let request = HostKeyValidationRequest(
                message: message,
                isKeyChanged: false
            )

            let result = await requestUserValidation(request)

            switch result {
            case .accept:
                // User accepted - save to known hosts
                let newHost = KnownHost(
                    hostname: hostnameCopy,
                    port: portCopy,
                    publicKeyData: publicKeyData,
                    keyType: keyType,
                    fingerprint: fingerprint
                )
                manager.addHost(newHost)
                logger.info("User accepted new host, added to known hosts")
                return true

            case .acceptOnce:
                // Accept but don't persist; remember in-memory for ancillary
                // connections in the same flow.
                SessionApprovedHostKeys.shared.remember(hostname: hostnameCopy, port: portCopy, publicKeyData: publicKeyData)
                logger.info("User accepted host for this session only")
                return true

            case .reject:
                logger.info("User rejected new host")
                return false
            }
        }
    }

    /// Generate SHA256 fingerprint in colon-separated hex format
    private func generateFingerprint(for hostKey: NIOSSHPublicKey) -> String {
        // Use the public OpenSSH string format
        // Format: "algorithm-id base64-encoded-key"
        let openSSHString = String(openSSHPublicKey: hostKey)

        // Extract just the base64 part (skip algorithm-id)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2, let keyData = Data(base64Encoded: String(components[1])) else {
            // Fallback: hash the entire string
            let fallbackData = openSSHString.data(using: .utf8) ?? Data()
            let hash = SHA256.hash(data: fallbackData)
            let fingerprint = hash.compactMap { String(format: "%02x", $0) }.joined(separator: ":")
            return "SHA256:\(fingerprint)"
        }

        // Compute SHA256 hash of the key data
        let hash = SHA256.hash(data: keyData)

        // Convert to colon-separated hex
        let fingerprint = hash.compactMap { String(format: "%02x", $0) }.joined(separator: ":")

        return "SHA256:\(fingerprint)"
    }

    /// Get the key type as a string
    private func getKeyType(from hostKey: NIOSSHPublicKey) -> String {
        // Extract from OpenSSH format
        let openSSHString = String(openSSHPublicKey: hostKey)
        let components = openSSHString.split(separator: " ")
        return components.first.map(String.init) ?? "unknown"
    }

    /// Serialize public key to base64 string for storage
    private func serializePublicKey(_ hostKey: NIOSSHPublicKey) throws -> String {
        // Use the OpenSSH public string format and extract the base64 part
        let openSSHString = String(openSSHPublicKey: hostKey)
        let components = openSSHString.split(separator: " ", maxSplits: 1)
        guard components.count >= 2 else {
            throw HostKeySerializationError()
        }
        return String(components[1])
    }
}

/// Error thrown when host key is rejected
struct HostKeyRejectedError: Error, LocalizedError {
    var errorDescription: String? {
        "Host key was rejected by user"
    }
}
