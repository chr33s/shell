# Contributing

Thanks for helping improve the rootshell-maintained Citadel fork. Focused bug fixes, tests, documentation improvements, and features that fit the SSH-library scope are welcome.

The roadmap is driven by rootshell's requirements. Maintainer response and review are best effort; this project does not provide a support SLA.

## Before opening an issue

- Search existing issues and confirm the problem occurs with the latest fork release or `main`.
- Reduce bugs to the smallest practical reproducer.
- Include the Citadel version or commit, Xcode and Swift versions, Apple platform and OS version, and SSH peer implementation.
- Remove credentials, hostnames, IP addresses, private keys, user data, and sensitive log content.
- Report rootshell application behavior in the [rootshell issue tracker](https://github.com/kitknox/rootshell/issues).
- Report security vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Pull requests

Keep each pull request narrowly scoped. Before submitting:

1. Add or update tests for behavioral changes.
2. Run `swift package dump-package`, `swift test`, and `swift build -c release` with the supported Apple toolchain.
3. Update public API documentation, README examples, and the changelog when applicable.
4. Confirm the change includes no secrets, generated build products, or unrelated formatting.

By submitting a contribution, you agree that it may be distributed under this repository's MIT license. No contributor license agreement is required.

## Upstream Citadel policy

This repository does not automatically track upstream Citadel. Contributions must not merge upstream branches or tags, introduce automated synchronization, or bundle unrelated upstream commits.

Upstream work may be adopted only when the maintainer has explicitly approved that specific change in advance. A pull request must identify any upstream-derived code and preserve its original authorship and licensing.
