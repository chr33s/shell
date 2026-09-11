# Changelog

All notable changes to the rootshell-maintained Citadel fork are documented here.

This project follows semantic versioning while it remains pre-1.0. The inherited upstream tags through `0.11.1` predate the rootshell fork release line.

## [0.13.0] - Unreleased

### Added

- SSH agent forwarding, including identity listing and signature requests.
- Remote TCP forwarding and OpenSSH stream-local forwarding.
- Direct stream-local channels for Unix-domain socket connections.
- Bidirectional command execution and improved PTY/TTY streaming.
- Configurable login timeouts, SSH keepalives, channel window tuning, login banners, and negotiated-algorithm reporting.
- OpenSSH user certificates and host-certificate algorithm advertisement.
- `sntrup761x25519-sha512` and `mlkem768x25519-sha256` hybrid key exchange.
- ML-DSA-44, ML-DSA-65, ML-DSA-87, and hybrid ML-DSA-44 + Ed25519 signature support.
- Encrypt-then-MAC transport protection and additional AES compatibility algorithms.

### Changed

- Raised the package's supported Apple deployment targets and modernized NIO usage.
- Pinned `swift-crypto` for compatibility with the ML-DSA bridge.
- Hardened SSH parsing, buffer handling, authentication retry behavior, and connection cleanup.

### Fixed

- Buffer-capacity traps in SSH string writers.
- Remote-forwarding failures on Network.framework-backed connections.
- Hybrid secret encoding for `sntrup761x25519-sha512`.
- Several force unwraps and fatal parsing paths in OpenSSH key handling.

[0.13.0]: https://github.com/kitknox/Citadel-rootshell/releases/tag/0.13.0
