# Security policy

## Supported versions

Security fixes are made on a best-effort basis for the latest published rootshell-fork release and the current `main` branch. Older releases are not supported.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue, discussion, or pull request.

Use GitHub's [private vulnerability reporting form](https://github.com/kitknox/Citadel-rootshell/security/advisories/new). Include:

- The affected release or commit.
- A clear description of the impact and affected SSH role or algorithm.
- Reproduction steps or a minimal proof of concept.
- Any known mitigations.
- Whether the issue has been disclosed anywhere else.

Remove real credentials, private keys, production host details, and unrelated user data. The maintainer will assess reports and coordinate disclosure on a best-effort basis; no response or remediation SLA is promised.

## Cryptography notice

The post-quantum additions and the bridge into `swift-crypto`'s vendored BoringSSL implementation have not received an independent security audit. Availability annotations and successful interoperability tests are not a security certification.
