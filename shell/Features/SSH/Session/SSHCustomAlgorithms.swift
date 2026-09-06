//
//  SSHCustomAlgorithms.swift
//  shell
//
//  Centralized registration of custom NIOSSH key algorithms.
//

import Citadel
import NIOSSH

/// Registers every custom public-key algorithm the app can parse (RSA,
/// ML-DSA hybrid + pure, Apple FIDO2). NIOSSH registration is global,
/// idempotent, and lock-protected; call from any path that parses keys,
/// certificates, or CA lines — those can all run before the first SSH
/// connection performs its own registration.
enum SSHCustomAlgorithms {
    static func ensureRegistered() {
        // Use Citadel's single default public-key/signature list so parsing
        // before a connection and connection setup cannot drift apart.
        SSHAlgorithms.all.registerPublicKeyAlgorithms()

        NIOSSHAlgorithms.register(keyExchangeAlgorithm: Sntrup761X25519Sha512.self)
        NIOSSHAlgorithms.register(keyExchangeAlgorithm: DiffieHellmanGroup14Sha256.self)
        NIOSSHAlgorithms.register(keyExchangeAlgorithm: DiffieHellmanGroup14Sha1.self)
        NIOSSHAlgorithms.register(keyExchangeAlgorithm: MLKem768X25519Sha256.self)

        NIOSSHAlgorithms.register(transportProtectionScheme: AES256CTR_ETM.self)
        NIOSSHAlgorithms.register(transportProtectionScheme: AES128CTR_ETM.self)
        NIOSSHAlgorithms.register(transportProtectionScheme: AES256CTR.self)
        NIOSSHAlgorithms.register(transportProtectionScheme: AES128CTR.self)
    }
}
