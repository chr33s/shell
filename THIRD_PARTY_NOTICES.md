# Third-Party Notices

rootshell is built with and distributes software, fonts, data, and other
materials from third parties. We are grateful to their authors and
contributors.

## What the rootshell MIT license covers

The repository's [`LICENSE`](LICENSE) applies to the original rootshell source
code and documentation authored by Rootshell LLC and Kit Knox, except where a
file or directory says otherwise.

That MIT license does **not** relicense:

- third-party source code, binary frameworks, packages, or command-line tools;
- bundled fonts, editor runtimes, sounds, data sets, or other assets; or
- code derived from a third-party project where the upstream license continues
  to apply.

Those materials remain subject to their respective copyright notices and
license terms. Our changes to a third-party project are licensed as stated in
that project's source repository and license files. No trademark rights are
granted by the rootshell MIT license.

This document consolidates the acknowledgements shown in the app. Some items
are included only in particular platform, region, or distribution builds.
Swift Package Manager dependencies may also have transitive dependencies; the
license files shipped in or referenced by those packages remain controlling.
If this summary differs from an upstream license, the upstream license controls.

## Core components and bundled tools

| Project | Copyright or acknowledgement | License |
| --- | --- | --- |
| [Ghostty / libghostty](https://github.com/ghostty-org/ghostty) | Copyright (c) 2024 Mitchell Hashimoto and Ghostty contributors | MIT |
| [ios_system](https://github.com/holzschu/ios_system) | Copyright (c) 2018 Nicolas Holzschuch | BSD 3-Clause |
| [jq](https://github.com/jqlang/jq) | Copyright (c) 2012 Stephen Dolan | MIT |
| [Vim](https://github.com/vim/vim) | Copyright (c) 1991-2024 Bram Moolenaar and the Vim contributors | Vim License |
| [curl](https://github.com/curl/curl) | Copyright (c) 1996-2026 Daniel Stenberg and many contributors | curl License |
| [Helix Editor](https://github.com/helix-editor/helix) | Copyright (c) 2020 Blaž Hrastnik and Helix contributors | MPL 2.0 |
| [gitoxide](https://github.com/GitoxideLabs/gitoxide) | Copyright (c) Sebastian Thiel and gitoxide contributors | MIT or Apache 2.0 |
| [bat](https://github.com/sharkdp/bat) | Copyright (c) 2018-2023 bat-developers | MIT or Apache 2.0 |
| [ripgrep](https://github.com/BurntSushi/ripgrep) | Copyright (c) 2015 Andrew Gallant | Unlicense or MIT |
| [libgit2](https://github.com/libgit2/libgit2) | Copyright (c) the libgit2 contributors | GPL 2.0 with linking exception |
| [libarchive](https://github.com/libarchive/libarchive) | Copyright (c) 2003-2024 Tim Kientzle and contributors | BSD 2-Clause and per-file terms |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Copyright (c) 2006-2013 Andy Matuschak and Sparkle contributors | MIT; Standalone Catalyst builds only |

The app uses maintained rootshell forks or binary-package wrappers for some of
these projects. A wrapper does not change the license of the software it
contains. The exact source, modification notices, and license text of every
Swift package a build links are checked in under `vendor/<package>/` at the
revision recorded in `vendor/manifest.lock`; each package's `Package.swift`
there is mechanically rewritten to resolve locally, and nothing else is
changed. See the corresponding package repository for upstream history.

Joe's Own Editor is an optional, debug-only component licensed under the GNU
GPL. Its package and the support files under `Resources/joe` are stripped from
distribution builds and are not covered by the rootshell MIT license. See the
[rootshell JOE fork](https://github.com/kitknox/joe-rootshell) for its source
and complete licensing information.

## Fonts

| Font project | Copyright or acknowledgement | License |
| --- | --- | --- |
| [Geist Mono](https://github.com/vercel/geist-font) | Copyright (c) 2023 Vercel | SIL Open Font License 1.1 |
| [Nerd Fonts](https://github.com/ryanoasis/nerd-fonts) | Copyright (c) 2014 Ryan L McIntyre | MIT; individual fonts and glyph sources retain their own licenses, including SIL OFL 1.1 |

The rootshell MIT license does not apply to the font files under
`Resources/fonts`.

## SSH, networking, and remote access

| Project or data source | Copyright or acknowledgement | License |
| --- | --- | --- |
| [Citadel](https://github.com/orlandos-nl/Citadel) | Copyright (c) 2022 Orlandos | MIT |
| [trzsz-ssh (tssh)](https://github.com/trzsz/trzsz-ssh) | Copyright (c) 2023-2026 The Trzsz SSH Authors | MIT |
| [CryptoSwift](https://github.com/krzyzanowskim/CryptoSwift) | Copyright (c) 2014 Marcin Krzyżanowski | zlib License |
| [YubiKit](https://github.com/kitknox/yubikit-swift-rootshell) | Copyright (c) Yubico AB | Apache 2.0 |
| [IPinfo data](https://ipinfo.io) | IP address data powered by IPinfo | CC BY-SA 4.0 |
| [croc](https://github.com/schollz/croc) | Copyright (c) 2017-2025 Zack Scholl | MIT |

CryptoSwift requires the following acknowledgement:

> This product includes software developed by Marcin Krzyzanowski.

## Apple open-source projects

| Project | Copyright or acknowledgement | License |
| --- | --- | --- |
| [Swift NIO](https://github.com/apple/swift-nio) | Copyright (c) Apple Inc. and the SwiftNIO project authors | Apache 2.0 |
| [Swift NIO SSH](https://github.com/apple/swift-nio-ssh) | Copyright (c) Apple Inc. and the SwiftNIO SSH project authors | Apache 2.0 |
| [Swift Crypto](https://github.com/apple/swift-crypto) | Copyright (c) Apple Inc. and the Swift Crypto project authors | Apache 2.0 |

## Sound Effects

rootshell includes original synthesized waveforms and sounds sourced from
[Freesound](https://freesound.org) under the CC0 1.0 Universal public-domain
dedication. The rootshell MIT license does not apply to third-party sound files.

## Complete license terms

Complete license terms and copyright notices are available in each linked
project and in the source or binary package resolved for a build. In
particular:

- [Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0)
- [BSD 2-Clause License](https://opensource.org/license/bsd-2-clause)
- [BSD 3-Clause License](https://opensource.org/license/bsd-3-clause)
- [Creative Commons Attribution-ShareAlike 4.0](https://creativecommons.org/licenses/by-sa/4.0/legalcode)
- [CC0 1.0 Universal](https://creativecommons.org/publicdomain/zero/1.0/legalcode)
- [GNU GPL 2.0](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
- [MIT License](https://opensource.org/license/mit)
- [Mozilla Public License 2.0](https://www.mozilla.org/MPL/2.0/)
- [SIL Open Font License 1.1](https://openfontlicense.org/open-font-license-official-text/)
- [The Unlicense](https://unlicense.org)

The Vim, curl, CryptoSwift, and libgit2 linking-exception terms are
project-specific; use the license file in the linked project rather than a
generic license summary.
