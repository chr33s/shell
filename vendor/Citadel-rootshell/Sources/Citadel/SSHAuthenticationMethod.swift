import NIOCore
import NIOSSH
import Crypto

/// Selects the RSA/SHA-1 compatibility attempt using the same semantics as
/// OpenSSH's `server-sig-algs` handling.
public enum SSHRSASignaturePolicy {
    /// Returns whether an `ssh-rsa` user-authentication attempt is useful.
    ///
    /// An absent RFC 8308 advertisement identifies a legacy or affected peer,
    /// so the base RSA algorithm remains eligible. An explicit list is
    /// authoritative, and advertising RSA/SHA-2 makes a retry after rejection
    /// redundant because the server already considered the modern key offer.
    public static func shouldAttemptLegacySHA1(
        serverSignatureAlgorithms: Set<String>?
    ) -> Bool {
        guard let serverSignatureAlgorithms else {
            return true
        }
        return serverSignatureAlgorithms.contains(Insecure.RSA.SHA1Signature.signaturePrefix)
            && !serverSignatureAlgorithms.contains(Insecure.RSA.Signature.signaturePrefix)
    }
}

/// Represents an authentication method.
public final class SSHAuthenticationMethod: NIOSSHClientUserAuthenticationDelegate {
    private enum Implementation {
        case custom(NIOSSHClientUserAuthenticationDelegate)
        case user(
            String,
            offer: NIOSSHUserAuthenticationOffer.Offer,
            requiredServerSignatureAlgorithm: String?
        )
    }
    
    private let allImplementations: [Implementation]
    private var implementations: [Implementation]
    private var serverSignatureAlgorithms: Set<String>?

    private func permits(requiredServerSignatureAlgorithm algorithm: String) -> Bool {
        if algorithm == Insecure.RSA.SHA1Signature.signaturePrefix {
            return SSHRSASignaturePolicy.shouldAttemptLegacySHA1(
                serverSignatureAlgorithms: serverSignatureAlgorithms
            )
        }
        return serverSignatureAlgorithms?.contains(algorithm) == true
    }
    
    internal init(
        username: String,
        offer: NIOSSHUserAuthenticationOffer.Offer
    ) {
        self.allImplementations = [
            .user(username, offer: offer, requiredServerSignatureAlgorithm: nil),
        ]
        self.implementations = allImplementations
    }

    internal init(
        username: String,
        offers: [(
            offer: NIOSSHUserAuthenticationOffer.Offer,
            requiredServerSignatureAlgorithm: String?
        )]
    ) {
        self.allImplementations = offers.map {
            .user(
                username,
                offer: $0.offer,
                requiredServerSignatureAlgorithm: $0.requiredServerSignatureAlgorithm
            )
        }
        self.implementations = allImplementations
    }
    
    internal init(
        custom: NIOSSHClientUserAuthenticationDelegate
    ) {
        self.allImplementations = [.custom(custom)]
        self.implementations = allImplementations
    }
    
    /// Creates a password based authentication method.
    /// - Parameters:
    ///  - username: The username to authenticate with.
    /// - password: The password to authenticate with.
    public static func passwordBased(username: String, password: String) -> SSHAuthenticationMethod {
        return SSHAuthenticationMethod(username: username, offer: .password(.init(password: password)))
    }
    
    /// Creates a public key based authentication method.
    /// - Parameters: 
    /// - username: The username to authenticate with.
    /// - privateKey: The private key to authenticate with.
    public static func rsa(username: String, privateKey: Insecure.RSA.PrivateKey) -> SSHAuthenticationMethod {
        SSHAuthenticationMethod(
            username: username,
            offers: [
                (
                    offer: .privateKey(.init(privateKey: .init(custom: privateKey))),
                    requiredServerSignatureAlgorithm: nil
                ),
                (
                    offer: .privateKey(.init(privateKey: privateKey.legacySHA1Key)),
                    requiredServerSignatureAlgorithm: "ssh-rsa"
                ),
            ]
        )
    }
    
    /// Creates a public key based authentication method.
    /// - Parameters: 
    /// - username: The username to authenticate with.
    /// - privateKey: The private key to authenticate with.
    public static func ed25519(username: String, privateKey: Curve25519.Signing.PrivateKey) -> SSHAuthenticationMethod {
        return SSHAuthenticationMethod(username: username, offer: .privateKey(.init(privateKey: .init(ed25519Key: privateKey))))
    }
    
    /// Creates a public key based authentication method.
    /// - Parameters: 
    /// - username: The username to authenticate with.
    /// - privateKey: The private key to authenticate with.
    public static func p256(username: String, privateKey: P256.Signing.PrivateKey) -> SSHAuthenticationMethod {
        return SSHAuthenticationMethod(username: username, offer: .privateKey(.init(privateKey: .init(p256Key: privateKey))))
    }
    
    /// Creates a public key based authentication method.
    /// - Parameters: 
    /// - username: The username to authenticate with.
    /// - privateKey: The private key to authenticate with.
    public static func p384(username: String, privateKey: P384.Signing.PrivateKey) -> SSHAuthenticationMethod {
        return SSHAuthenticationMethod(username: username, offer: .privateKey(.init(privateKey: .init(p384Key: privateKey))))
    }
    
    /// Creates a public key based authentication method.
    /// - Parameters: 
    /// - username: The username to authenticate with.
    /// - privateKey: The private key to authenticate with.
    public static func p521(username: String, privateKey: P521.Signing.PrivateKey) -> SSHAuthenticationMethod {
        return SSHAuthenticationMethod(username: username, offer: .privateKey(.init(privateKey: .init(p521Key: privateKey))))
    }
    
    /// Creates an OpenSSH certificate based authentication method.
    ///
    /// The certificate is offered through the publickey method: the userauth request carries the
    /// certificate blob and its cert algorithm name, signed by `privateKey` (which must correspond
    /// to the certificate's embedded public key).
    /// - Parameters:
    /// - username: The username to authenticate with.
    /// - privateKey: The private key matching the certificate's embedded public key.
    /// - certifiedKey: The OpenSSH user certificate, e.g. parsed via
    ///   `NIOSSHCertifiedPublicKey(openSSHCertifiedPublicKey:)`.
    public static func certificate(username: String, privateKey: NIOSSHPrivateKey, certifiedKey: NIOSSHCertifiedPublicKey) -> SSHAuthenticationMethod {
        return SSHAuthenticationMethod(username: username, offer: .privateKey(.init(privateKey: privateKey, certifiedKey: certifiedKey)))
    }

    /// Creates an OpenSSH certificate based authentication method for an RSA key.
    /// The userauth request uses `rsa-sha2-256-cert-v01@openssh.com` with an `rsa-sha2-256` signature.
    public static func rsaCertificate(username: String, privateKey: Insecure.RSA.PrivateKey, certifiedKey: NIOSSHCertifiedPublicKey) -> SSHAuthenticationMethod {
        return SSHAuthenticationMethod(username: username, offer: .privateKey(.init(privateKey: .init(custom: privateKey), certifiedKey: certifiedKey)))
    }

    public static func custom(_ auth: NIOSSHClientUserAuthenticationDelegate) -> SSHAuthenticationMethod {
        return SSHAuthenticationMethod(custom: auth)
    }
    
    public func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        while case .user(_, _, let requiredAlgorithm)? = implementations.first,
              let requiredAlgorithm,
              !permits(requiredServerSignatureAlgorithm: requiredAlgorithm) {
            _ = implementations.removeFirst()
        }

        if implementations.isEmpty {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }

        // Peek at the first implementation without removing it yet
        let implementation = implementations.first!

        switch implementation {
        case .user(let username, offer: let offer, requiredServerSignatureAlgorithm: _):
            // For user-based auth, remove from array (single attempt per offer)
            _ = implementations.removeFirst()

            switch offer {
            case .password:
                guard availableMethods.contains(.password) else {
                    nextChallengePromise.fail(SSHClientError.unsupportedPasswordAuthentication)
                    return
                }
            case .hostBased:
                guard availableMethods.contains(.hostBased) else {
                    nextChallengePromise.fail(SSHClientError.unsupportedHostBasedAuthentication)
                    return
                }
            case .privateKey:
                guard availableMethods.contains(.publicKey) else {
                    nextChallengePromise.fail(SSHClientError.unsupportedPrivateKeyAuthentication)
                    return
                }
            case .keyboardInteractive:
                guard availableMethods.contains(.keyboardInteractive) else {
                    nextChallengePromise.fail(SSHClientError.unsupportedKeyboardInteractiveAuthentication)
                    return
                }
            case .none:
                ()
            }

            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))

        case .custom(let customDelegate):
            // For custom delegates, create a wrapper promise that intercepts nil responses
            // to know when the delegate is exhausted (so we can try the next implementation)
            let eventLoop = nextChallengePromise.futureResult.eventLoop
            let wrapperPromise = eventLoop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)

            wrapperPromise.futureResult.whenComplete { result in
                switch result {
                case .success(let offer):
                    if offer == nil {
                        // Custom delegate is exhausted, remove it and try next implementation
                        _ = self.implementations.removeFirst()
                        // Recursively try the next implementation
                        self.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: nextChallengePromise)
                    } else {
                        // Custom delegate provided an offer, pass it through
                        nextChallengePromise.succeed(offer)
                    }
                case .failure(let error):
                    // Custom delegate failed, propagate the error
                    _ = self.implementations.removeFirst()
                    nextChallengePromise.fail(error)
                }
            }

            customDelegate.nextAuthenticationType(availableMethods: availableMethods, nextChallengePromise: wrapperPromise)
        }
    }

    public func serverSignatureAlgorithmsReceived(_ algorithms: [String]) {
        self.serverSignatureAlgorithms = Set(algorithms)
        for implementation in allImplementations {
            if case .custom(let delegate) = implementation {
                delegate.serverSignatureAlgorithmsReceived(algorithms)
            }
        }
    }

    public func respondToKeyboardInteractiveChallenge(
        name: String,
        instruction: String,
        prompts: [NIOSSHKeyboardInteractivePrompt],
        responsePromise: EventLoopPromise<[String]>
    ) {
        // The active implementation is the one that produced the current offer.
        // For keyboard-interactive that is always a custom delegate (a non-nil
        // offer is not removed from `implementations`), so forward the challenge
        // to it. A static `.user` offer cannot answer interactive prompts.
        guard let implementation = implementations.first else {
            responsePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }

        switch implementation {
        case .custom(let customDelegate):
            customDelegate.respondToKeyboardInteractiveChallenge(
                name: name,
                instruction: instruction,
                prompts: prompts,
                responsePromise: responsePromise
            )
        case .user:
            responsePromise.fail(SSHClientError.unsupportedKeyboardInteractiveAuthentication)
        }
    }

    public func authenticationSucceededPartially() {
        // Forward to the active wrapped delegate so it can avoid reusing an
        // accepted credential for a subsequent factor.
        if case .custom(let customDelegate) = implementations.first {
            customDelegate.authenticationSucceededPartially()
        }
    }
}
