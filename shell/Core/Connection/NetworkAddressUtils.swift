//
//  NetworkAddressUtils.swift
//  shell
//
//  Utilities for network address detection and resolution
//

import Foundation

/// Network address utilities for SSH connections.
/// `nonisolated`: pure address math and blocking DNS, neither of which belongs on the main actor.
nonisolated enum NetworkAddressUtils {

    /// Default timeout for DNS resolution (5 seconds)
    private static let dnsTimeout: TimeInterval = 5.0

    // MARK: - Address Classification

    /// Checks if an IPv4 address is in the CGNAT range (100.64.0.0/10, RFC 6598)
    /// These addresses are used by VPNs/proxies (Tailscale, ISPs) that often lack IPv6 support
    static func isCGNATAddress(_ ipString: String) -> Bool {
        let octets = ipString.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }

        // 100.64.0.0/10 means first octet is 100, second octet is 64-127
        // In binary: 100.01xxxxxx.x.x (first 10 bits fixed)
        return octets[0] == 100 && octets[1] >= 64 && octets[1] <= 127
    }

    /// Checks if an IPv4 address is routable (not link-local or loopback)
    /// Private ranges (10.x, 172.16-31.x, 192.168.x) ARE considered routable since
    /// they're reachable within the network/VPN
    static func isRoutableIPv4(_ ipString: String) -> Bool {
        let octets = ipString.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }

        // Exclude loopback (127.x.x.x)
        if octets[0] == 127 { return false }

        // Exclude link-local (169.254.x.x)
        if octets[0] == 169 && octets[1] == 254 { return false }

        // Accept all other addresses including private ranges
        return true
    }

    // MARK: - DNS Resolution (Non-Blocking)

    /// Resolves hostname and returns IPv4 if it's in CGNAT range (100.64.0.0/10)
    /// Returns nil if not a CGNAT address (use normal connection)
    /// This is used to force IPv4-only connections for VPNs that lack IPv6 support
    ///
    /// Runs DNS resolution on a background thread with a 5-second timeout to avoid
    /// blocking the main thread.
    static func resolveToCGNATIPv4(hostname: String) async -> String? {
        // Skip if already an IPv6 address
        if hostname.contains(":") { return nil }

        // Check if it's already an IPv4 address
        let octets = hostname.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            // Already an IP - check directly
            return isCGNATAddress(hostname) ? hostname : nil
        }

        // Resolve with timeout
        return await withTimeoutResolution(hostname: hostname) { ipString in
            isCGNATAddress(ipString)
        }
    }

    /// Resolves a hostname and returns a routable IPv4 address (excluding link-local, loopback)
    /// Returns nil if no routable address is found
    ///
    /// Runs DNS resolution on a background thread with a 5-second timeout to avoid
    /// blocking the main thread. This is especially important for .local hostnames
    /// which use mDNS/Bonjour and can be slow on VPNs.
    static func resolveToRoutableIPv4(hostname: String) async -> String? {
        // Skip if already an IPv6 address
        if hostname.contains(":") { return nil }

        // Check if it's already an IPv4 address
        let octets = hostname.split(separator: ".").compactMap { Int($0) }
        if octets.count == 4 {
            // Already an IP - check directly
            return isRoutableIPv4(hostname) ? hostname : nil
        }

        // Resolve with timeout
        return await withTimeoutResolution(hostname: hostname) { ipString in
            isRoutableIPv4(ipString)
        }
    }

    // MARK: - Private Implementation

    /// Performs DNS resolution on a background thread with a timeout.
    /// Returns the first IPv4 address that matches the provided filter, or nil on timeout/failure.
    private static func withTimeoutResolution(
        hostname: String,
        filter: @escaping @Sendable (String) -> Bool
    ) async -> String? {
        // NOT a task group: a group awaits every child when its body returns.
        // `getaddrinfo` ignores cancellation and can sit on a dead resolver far
        // longer than `dnsTimeout`, so cancelling the child would still wait it
        // out. `withTimeout` races the lookup and hands control back on schedule.
        let resolved = try? await withTimeout(seconds: dnsTimeout) {
            await performDNSResolution(hostname: hostname, filter: filter)
        }
        return resolved ?? nil
    }

    /// Blocking `getaddrinfo` on the concurrent pool. It does not observe
    /// cancellation; the caller bounds it with `withTimeout`.
    @concurrent
    private static func performDNSResolution(
        hostname: String,
        filter: @escaping @Sendable (String) -> Bool
    ) async -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        guard status == 0, let addrInfo = result else { return nil }
        defer { freeaddrinfo(result) }

        var current = addrInfo
        while true {
            if current.pointee.ai_family == AF_INET {
                let addr = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let ipData = withUnsafeBytes(of: addr.sin_addr) { Data($0) }

                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, [UInt8](ipData), &buffer, socklen_t(INET_ADDRSTRLEN))
                let ipString = String(cString: buffer)
                if filter(ipString) { return ipString }
            }
            guard let next = current.pointee.ai_next else { break }
            current = next
        }
        return nil
    }
}
