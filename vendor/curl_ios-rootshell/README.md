# curl for rootshell

This repository is the [rootshell](https://www.rootshell.com)-maintained fork
of [curl/curl](https://github.com/curl/curl). It packages the existing
rootshell curl command as a public Swift binary package and preserves the
ios_system stream routing, repeated-invocation safety, and cooperative
cancellation required by rootshell. The fork is maintained independently and
does not automatically track subsequent upstream changes.

The `curl_ios` framework includes curl 8.22.0, OpenSSL 3.5.4, and a pinned
nghttp2 checkout. It dynamically links the host application's `ios_system`
framework and supports:

- iOS devices and arm64 simulators
- Mac Catalyst on arm64 and x86_64
- visionOS devices and arm64 simulators

## Swift Package Manager

Add `https://github.com/kitknox/curl_ios-rootshell.git` with an exact
dependency on `0.2.1`, then link the `curl_ios` product. The package downloads
the public `curl_ios.xcframework.zip` release asset.

```swift
.package(
    url: "https://github.com/kitknox/curl_ios-rootshell.git",
    exact: "0.2.1"
)
```

The host must also link rootshell's `ios_system` product, which supplies the
per-session streams and cancellation symbols used by `curl_main`.

## Apple framework development

Initialize the pinned nghttp2 source and place the `ios_system` and
`openssl_ios` checkouts beside this repository:

```bash
git submodule update --init
cd ../ios_system
swift run --package-path xcfs build ios_system
cd ../openssl_ios
OPENSSL_SOURCE_DIR=../openssl ./build.sh
cd ../curl_ios
swift run --package-path xcfs build
```

`IOS_SYSTEM_SOURCE_DIR` and `OPENSSL_IOS_SOURCE_DIR` can override the sibling
checkout locations. Generated frameworks and archives remain under the
ignored `.build` directory.

The release gate checks every OpenSSL object's deployment metadata, all framework
slices and dSYMs, and the iOS device atomic routines. It rejects binaries compiled
for a newer CPU baseline even if the final framework advertises an older OS.
To run it on local build output:

```bash
python3 scripts/test_apple_compatibility.py
python3 scripts/verify-apple-compatibility.py \
  --openssl-build ../openssl_ios/.build \
  --xcframework .build/curl_ios.xcframework
```

Release maintainers publish a clean, audited build with:

```bash
./scripts/release-rootshell.sh v0.2.1
```

Report rootshell application problems in the
[rootshell issue tracker](https://github.com/kitknox/rootshell-app/issues).
Report reproducible upstream curl problems to the upstream project.

---

<!--
Copyright (C) Daniel Stenberg, <daniel@haxx.se>, et al.

SPDX-License-Identifier: curl
-->

# [![curl logo](https://curl.se/logo/curl-logo.svg)](https://curl.se/)

curl is a command-line tool for transferring data from or to a server using
URLs. It supports these protocols: DICT, FILE, FTP, FTPS, GOPHER, GOPHERS,
HTTP, HTTPS, IMAP, IMAPS, LDAP, LDAPS, MQTT, MQTTS, POP3, POP3S, RTSP, SCP,
SFTP, SMB, SMBS, SMTP, SMTPS, TELNET, TFTP, WS and WSS.

Learn how to use curl by reading [the
man page](https://curl.se/docs/manpage.html) or [everything
curl](https://everything.curl.dev/).

Find out how to install curl by reading [the INSTALL
document](https://curl.se/docs/install.html).

libcurl is the library curl is using to do its job. It is readily available to
be used by your software. Read [the libcurl
man page](https://curl.se/libcurl/c/libcurl.html) to learn how.

## Open Source

curl is Open Source and is distributed under an MIT-like
[license](https://curl.se/docs/copyright.html).

## Contact

Contact us on a suitable [mailing list](https://curl.se/mail/) or
use GitHub [issues](https://github.com/curl/curl/issues)/
[pull requests](https://github.com/curl/curl/pulls)/
[discussions](https://github.com/curl/curl/discussions).

All contributors to the project are listed in [the THANKS
document](https://curl.se/docs/thanks.html).

## Commercial support

For commercial support, maybe private and dedicated help with your problems or
applications using (lib)curl visit [the support page](https://curl.se/support.html).

## Website

Visit the [curl website](https://curl.se/) for the latest news and downloads.

## Source code

Download the latest source from the Git server:

    git clone https://github.com/curl/curl

## Security problems

Report suspected security problems
[privately](https://curl.se/dev/vuln-disclosure.html) and not in public.

## Backers

Thank you to all our backers :pray: [Become a backer](https://opencollective.com/curl#section-contribute).

## Sponsors

Support this project by becoming a [sponsor](https://curl.se/sponsors.html).
