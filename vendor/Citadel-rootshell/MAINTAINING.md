# Maintaining the rootshell fork

This document records the policies for maintaining and releasing `kitknox/Citadel-rootshell`.

## Upstream boundary

The provenance baseline is `orlandos-nl/Citadel` at tag `0.11.1`. The fork has an independent roadmap.

- Do not merge upstream branches or tags.
- Do not create automated upstream-sync pull requests.
- Do not cherry-pick upstream changes merely to remain current.
- Do not change the provenance baseline when upstream publishes a release.
- Use upstream repositories only for comparison, research, and attribution.

Adopting an upstream change requires a separate, explicitly scoped maintainer decision. Preserve the original commit authorship where practical, record the source commit in the resulting change, and include only the approved behavior.

## Release checklist

1. Confirm the working tree contains no unrelated changes or generated build products.
2. Review every change since the previous fork release and update `CHANGELOG.md`.
3. Run a secret scan over the current tree and complete Git history.
4. In a fresh clone, run `swift package dump-package`, `swift test`, and `swift build -c release` with the documented Apple toolchain.
5. Run the environment-dependent tests against a disposable OpenSSH server using non-sensitive credentials.
6. Confirm the dependency graph uses the intended public package locations and versions.
7. Confirm the README's compatibility, security, and installation information is current.
8. Create the release from a reviewed commit on `main`, add the semantic-version tag, and publish release notes from the changelog.

Inherited upstream tags must remain intact. Do not rewrite or squash the repository history for routine releases.

## Dependency maintenance

Dependency updates are reviewed and performed manually. Do not add Dependabot or another automated dependency-update service without an explicit maintainer decision.

The ML-DSA bridge relies on private, version-specific symbols and storage layouts from the pinned `swift-crypto` release. Revalidate its ABI assumptions and cryptographic test vectors before changing that pin.
