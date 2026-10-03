import Foundation
import LocalAuthentication
import os.log

/// The surface a key is being used through. Session authorization is tracked
/// per purpose so that authenticating a key for Shell's own SSH connections
/// never silently unlocks it for programs in the local shell (through the
/// local SSH agent), and vice versa (ssh-agent-bridge-v2-delta.md §5.1).
nonisolated enum SSHKeyAuthPurpose: Hashable, Sendable {
    case nativeSSH
    case localAgent
}

/// Manages session-based authentication for SSH keys
///
/// Tracks which keys have been authenticated during the current session
/// and handles time-based expiration of authentication.
///
/// Also provides auth deduplication for concurrent requests - if multiple
/// sign requests arrive for the same key simultaneously, only the first
/// one triggers a biometric prompt and others wait to share the result.
@MainActor
final class SSHKeyAuthManager {
    private nonisolated static let logger = Logger(subsystem: "dev.chr33s.shell", category: "SSHKeyAuthManager")

    static let shared = SSHKeyAuthManager()

    private struct Scope: Hashable {
        let keyID: UUID
        let purpose: SSHKeyAuthPurpose
    }

    /// Authenticated (key, purpose) pairs with their authentication timestamps
    private var authenticatedKeys: [Scope: Date] = [:]

    /// Session timeout in seconds (1 hour)
    let sessionTimeout: TimeInterval = 3600

    /// Track the active auth task for each key
    private var activeAuthTasks: [Scope: Task<Data, Error>] = [:]

    /// Cached LAContexts for Secure Enclave keys with `.perSession` auth.
    /// A single context per key is reused across connections so the user
    /// authenticates once and subsequent signs are silent within the OS
    /// biometric reuse window.
    private var secureEnclaveContexts: [Scope: LAContext] = [:]

    private init() {}

    // MARK: - Authentication Status

    /// Check if a key needs authentication
    /// - Parameter key: The SSH key to check
    /// - Returns: true if authentication is needed
    func needsAuthentication(for key: SSHKey, purpose: SSHKeyAuthPurpose = .nativeSSH) -> Bool {
        switch key.authRequirement {
        case .none:
            return false
        case .perUse:
            return true
        case .perSession:
            guard let authTime = authenticatedKeys[Scope(keyID: key.id, purpose: purpose)] else {
                return true
            }
            // Check if authentication has expired
            return Date().timeIntervalSince(authTime) > sessionTimeout
        }
    }

    /// Record that a key was successfully authenticated
    /// - Parameter keyID: The UUID of the authenticated key
    func recordAuthentication(for keyID: UUID, purpose: SSHKeyAuthPurpose = .nativeSSH) {
        authenticatedKeys[Scope(keyID: keyID, purpose: purpose)] = Date()
    }

    /// Clear authentication for a specific key, for one purpose or (nil) all.
    func clearAuthentication(for keyID: UUID, purpose: SSHKeyAuthPurpose? = nil) {
        authenticatedKeys = authenticatedKeys.filter { scope, _ in
            !(scope.keyID == keyID && (purpose == nil || scope.purpose == purpose))
        }
        secureEnclaveContexts = secureEnclaveContexts.filter { scope, _ in
            !(scope.keyID == keyID && (purpose == nil || scope.purpose == purpose))
        }
    }

    /// Clear every key's session authorization for one purpose — e.g. all
    /// local-agent sessions when the app backgrounds or the agent is disabled.
    func clearAuthentication(purpose: SSHKeyAuthPurpose) {
        authenticatedKeys = authenticatedKeys.filter { $0.key.purpose != purpose }
        secureEnclaveContexts = secureEnclaveContexts.filter { $0.key.purpose != purpose }
    }

    // MARK: - LAContext Management

    /// Create an LAContext configured for the given authentication requirement
    /// - Parameters:
    ///   - key: The SSH key being authenticated
    ///   - reason: The reason string to show to the user
    /// - Returns: Configured LAContext
    func createContext(for key: SSHKey, reason: String) -> LAContext {
        let context = LAContext()
        context.localizedReason = reason

        switch key.authRequirement {
        case .none:
            // No special configuration needed
            break
        case .perSession:
            // Allow biometric reuse within a short window
            context.touchIDAuthenticationAllowableReuseDuration = 10
        case .perUse:
            // Never reuse - always require fresh authentication
            context.touchIDAuthenticationAllowableReuseDuration = 0
        }

        return context
    }

    // MARK: - Secure Enclave Contexts

    /// Make a fresh, un-authenticated `LAContext` for a Secure Enclave key.
    /// The caller authenticates it (via `evaluateAccessControl`) and only then
    /// decides whether to cache + record the session — so a cancelled or
    /// failed prompt never marks the key authenticated (matches software
    /// keys, which record only after a successful authenticated load).
    ///
    /// - `.none`: returns `nil` (no biometric gate).
    /// - `.perUse`: reuse window 0, so every signing operation re-prompts.
    /// - `.perSession`: the OS-maximum reuse window, so a cached, authenticated
    ///   context can sign silently within a session.
    func makeSecureEnclaveContext(for key: SSHKey, reason: String) -> LAContext? {
        guard key.authRequirement != .none else { return nil }
        let context = LAContext()
        context.localizedReason = reason
        context.touchIDAuthenticationAllowableReuseDuration =
            (key.authRequirement == .perSession) ? LATouchIDAuthenticationMaximumAllowableReuseDuration : 0
        return context
    }

    /// The cached, already-authenticated perSession context for a key (valid
    /// only while the session has not expired — see ``needsAuthentication``).
    func cachedSecureEnclaveContext(for keyID: UUID, purpose: SSHKeyAuthPurpose = .nativeSSH) -> LAContext? {
        secureEnclaveContexts[Scope(keyID: keyID, purpose: purpose)]
    }

    /// Cache a perSession context after its biometric/passcode succeeded.
    func cacheSecureEnclaveContext(_ context: LAContext, for keyID: UUID, purpose: SSHKeyAuthPurpose = .nativeSSH) {
        secureEnclaveContexts[Scope(keyID: keyID, purpose: purpose)] = context
    }

    /// Forget a key's cached Secure Enclave contexts for every purpose (e.g.
    /// when the key is deleted).
    func clearSecureEnclaveContext(for keyID: UUID) {
        secureEnclaveContexts = secureEnclaveContexts.filter { $0.key.keyID != keyID }
    }

    // MARK: - Auth Deduplication

    /// Performs an authenticated key load with deduplication
    ///
    /// If multiple concurrent requests come in for the same key, only the first one
    /// triggers the actual auth operation. Subsequent requests wait and share the result.
    ///
    /// - Parameters:
    ///   - keyID: The UUID of the key to load
    ///   - loader: A closure that performs the actual authenticated load
    /// - Returns: The loaded key data
    /// - Throws: Error if auth fails or is cancelled
    func loadWithDeduplication(
        keyID: UUID,
        purpose: SSHKeyAuthPurpose = .nativeSSH,
        loader: @escaping () async throws -> Data
    ) async throws -> Data {
        let scope = Scope(keyID: keyID, purpose: purpose)
        // Check if there's already an active auth operation for this key and
        // purpose. Different purposes never share a prompt's result.
        if let existingTask = activeAuthTasks[scope] {
            Self.logger.info("Auth already in progress for key \(keyID.uuidString), waiting for result")
            return try await existingTask.value
        }

        // Create the dedup Task. The entry must live as long as the *shared*
        // Task body runs — NOT just as long as one awaiter is parked on it.
        // If we removed the entry on the creator's cancellation, a new caller
        // arriving while the inner Keychain/biometric work is still in flight
        // would see no entry and start a duplicate prompt for the same key.
        // Tie removal to the Task's own completion via the body itself, so
        // every awaiter (creator + later subscribers) shares one prompt.
        let task = Task<Data, Error> { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.activeAuthTasks.removeValue(forKey: scope)
                }
            }
            return try await loader()
        }

        // Insert before yielding. The Task body's defer schedules an
        // @MainActor removeValue hop, which can only run when MainActor is
        // free — i.e. after we yield at `try await task.value` below. So even
        // if the cooperative pool runs the Task body to completion before we
        // reach the await, the removeValue still has to queue behind this
        // synchronous insertion on MainActor. No "removed before inserted" race.
        activeAuthTasks[scope] = task
        Self.logger.info("Starting auth operation for key \(keyID.uuidString)")

        do {
            let result = try await task.value
            Self.logger.info("Auth operation completed successfully for key \(keyID.uuidString)")
            return result
        } catch {
            // Do NOT cancel `task` and do NOT remove the dict entry here.
            // Both would harm concurrent waiters sharing this same Task. The
            // Task body's own `defer` removes the entry exactly once, when
            // the underlying work actually finishes.
            Self.logger.info("Auth operation failed for key \(keyID.uuidString): \(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Biometric Availability

    /// Get the type of biometric authentication available
    var biometricType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    /// Human-readable name for the available biometric type
    var biometricTypeName: String {
        switch biometricType {
        case .faceID:
            return "Face ID"
        case .touchID:
            return "Touch ID"
        case .opticID:
            return "Optic ID"
        case .none:
            return "Passcode"
        @unknown default:
            return "Biometric"
        }
    }

    /// SF Symbol name for the available biometric type
    var biometricIconName: String {
        switch biometricType {
        case .faceID:
            return "faceid"
        case .touchID:
            return "touchid"
        case .opticID:
            return "opticid"
        case .none:
            return "lock"
        @unknown default:
            return "lock"
        }
    }
}
