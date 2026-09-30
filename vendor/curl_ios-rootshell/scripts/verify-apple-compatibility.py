#!/usr/bin/env python3
"""Reject Apple curl releases whose OpenSSL code exceeds the advertised OS/CPU floor."""

import argparse
import plistlib
import re
import subprocess
import sys
from pathlib import Path


# Mach-O platform IDs, minimum OS versions, and architectures.
OPENSSL_TARGETS = {
    "ios-arm64": (2, "14.0", {"arm64"}),
    "ios-arm64-simulator": (7, "14.0", {"arm64"}),
    "visionos-arm64": (11, "1.0", {"arm64"}),
    "visionos-arm64-simulator": (12, "1.0", {"arm64"}),
    "catalyst-arm64": (6, "14.0", {"arm64"}),
    "catalyst-x86_64": (6, "14.0", {"x86_64"}),
}
FRAMEWORK_SLICES = {
    "ios-arm64": (2, "14.0", {"arm64"}),
    "ios-arm64-simulator": (7, "14.0", {"arm64"}),
    "xros-arm64": (11, "1.0", {"arm64"}),
    "xros-arm64-simulator": (12, "1.0", {"arm64"}),
    "ios-arm64_x86_64-maccatalyst": (6, "14.0", {"arm64", "x86_64"}),
}
ATOMIC_SYMBOLS = tuple("_CRYPTO_atomic_" + suffix for suffix in (
    "add", "add64", "and", "or", "load", "load_int", "store",
))
# These instructions require RCpc/LSE, unavailable on the A10 in iPad7,11.
# Inspect only unconditional atomics, not OpenSSL's CPU-dispatched assembly.
NEWER_ATOMIC = re.compile(
    r"^(?:ldap(?:r|ur)|stlur|cas|swp|(?:ld|st)(?:add|clr|eor|set|smax|smin|umax|umin))"
)


def run(*args):
    return subprocess.run(
        [str(arg) for arg in args], check=True, text=True, capture_output=True
    ).stdout


def require_file(path):
    if not path.is_file():
        raise ValueError(f"missing file: {path}")


def version_tuple(version):
    return tuple((list(map(int, version.split("."))) + [0, 0])[:3])


def verify_load_commands(output, platform, minimum, label, count=1):
    records = re.findall(
        r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform (\d+)\s+minos ([\d.]+)",
        output,
    )
    if len(records) != count:
        raise ValueError(f"{label}: expected {count} build-version records, found {len(records)}")
    for actual_platform, actual_minimum in records:
        if int(actual_platform) != platform or version_tuple(actual_minimum) > version_tuple(minimum):
            raise ValueError(
                f"{label}: platform {actual_platform}, minimum {actual_minimum}; "
                f"expected platform {platform}, minimum <= {minimum}"
            )


def verify_architectures(path, expected):
    actual = set(run("xcrun", "lipo", "-archs", path).split())
    if actual != expected:
        raise ValueError(f"{path}: architectures {actual}, expected {expected}")


def verify_archive(path, platform, minimum, architectures):
    require_file(path)
    verify_architectures(path, architectures)
    output = run("xcrun", "otool", "-l", path)
    members = re.split(r"(?m)^" + re.escape(str(path)) + r"\(([^\n]+)\):\n", output)
    if len(members) == 1:
        raise ValueError(f"{path}: no object members found")
    for name, commands in zip(members[1::2], members[2::2]):
        verify_load_commands(commands, platform, minimum, f"{path}({name})")


def verify_atomic_disassembly(output, label):
    seen = set()
    current = None
    instruction_count = 0
    for line in output.splitlines():
        symbol = re.match(r"^[0-9a-f]+ <([^>]+)>:$", line)
        if symbol:
            current = symbol.group(1)
        instruction = re.match(r"^\s*[0-9a-f]+:\s+[0-9a-f]{8}\s+(\S+)", line)
        if instruction and current in ATOMIC_SYMBOLS:
            mnemonic = instruction.group(1)
            seen.add(current)
            instruction_count += 1
            if NEWER_ATOMIC.match(mnemonic) or mnemonic == "<unknown>":
                raise ValueError(f"{label}: unsupported instruction in {current}: {line.strip()}")
    missing = set(ATOMIC_SYMBOLS) - seen
    if missing:
        raise ValueError(f"{label}: missing/disassembly unavailable for {', '.join(sorted(missing))}")
    return instruction_count


def verify_atomics(path):
    require_file(path)
    output = run("xcrun", "llvm-objdump", "--disassemble-symbols=" + ",".join(ATOMIC_SYMBOLS), path)
    count = verify_atomic_disassembly(output, str(path))
    print(f"Compatible iOS atomics: {path} ({count} instructions)")


def verify_openssl(build):
    for name, (platform, minimum, architectures) in OPENSSL_TARGETS.items():
        for library in ("libssl.a", "libcrypto.a"):
            path = build / "targets" / name / "install" / "lib" / library
            verify_archive(path, platform, minimum, architectures)
        print(f"Compatible OpenSSL objects: {name}")
    verify_atomics(build / "targets/ios-arm64/install/lib/libcrypto.a")


def uuids(path):
    return set(re.findall(r"UUID: ([0-9A-Fa-f-]+) \(([^)]+)\)", run("xcrun", "dwarfdump", "--uuid", path)))


def verify_xcframework(root):
    require_file(root / "Info.plist")
    with (root / "Info.plist").open("rb") as source:
        libraries = plistlib.load(source)["AvailableLibraries"]
    if len(libraries) != len(FRAMEWORK_SLICES) or {entry["LibraryIdentifier"] for entry in libraries} != set(FRAMEWORK_SLICES):
        raise ValueError(f"{root}: unexpected XCFramework slices")
    for name, (platform, minimum, architectures) in FRAMEWORK_SLICES.items():
        binary = root / name / "curl_ios.framework/curl_ios"
        dsym = root / name / "dSYMs/curl_ios.framework.dSYM/Contents/Resources/DWARF/curl_ios"
        require_file(binary)
        require_file(dsym)
        verify_architectures(binary, architectures)
        verify_load_commands(run("xcrun", "otool", "-arch", "all", "-l", binary),
                             platform, minimum, str(binary), len(architectures))
        binary_uuids = uuids(binary)
        if len(binary_uuids) != len(architectures) or binary_uuids != uuids(dsym):
            raise ValueError(f"{binary}: missing or mismatched dSYM UUIDs")
        exports = run("xcrun", "nm", "-arch", "all", "-gU", binary)
        if len(re.findall(r"(?m) _curl_main$", exports)) != len(architectures):
            raise ValueError(f"{binary}: curl_main export missing")
        if run("xcrun", "otool", "-arch", "all", "-L", binary).count("@rpath/ios_system.framework/") != len(architectures):
            raise ValueError(f"{binary}: ios_system runtime dependency missing")
        print(f"Compatible framework metadata: {name}")
    verify_atomics(root / "ios-arm64/curl_ios.framework/curl_ios")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openssl-build", type=Path)
    parser.add_argument("--xcframework", type=Path)
    args = parser.parse_args()
    if not args.openssl_build and not args.xcframework:
        parser.error("provide --openssl-build and/or --xcframework")
    try:
        if args.openssl_build:
            verify_openssl(args.openssl_build.resolve())
        if args.xcframework:
            verify_xcframework(args.xcframework.resolve())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
