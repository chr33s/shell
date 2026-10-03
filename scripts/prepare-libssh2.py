#!/usr/bin/env python3
"""Prepare the checksum-verified upstream libssh2 for App Store packaging."""

import pathlib
import plistlib
import re
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True)


def prepare(source, output):
    metadata = plistlib.loads((source / "Info.plist").read_bytes())
    libraries = [lib for lib in metadata["AvailableLibraries"]
                 if lib["SupportedPlatform"] == "ios"]
    if len(libraries) != 3:
        raise ValueError("Expected device, simulator, and Catalyst libssh2 slices")
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    for lib in libraries:
        identifier = lib["LibraryIdentifier"]
        shutil.copytree(source / identifier, output / identifier, symlinks=True)
        framework = output / identifier / lib["LibraryPath"]
        binary = framework / "libssh2"
        # These upstream signatures become invalid when the binary/plist changes.
        # Xcode signs the prepared framework when embedding it into the app.
        if (framework / "_CodeSignature").exists() or (framework / "Versions/Current/_CodeSignature").exists():
            subprocess.run(["codesign", "--remove-signature", str(framework)], check=True)
        if "arm64e" in run("xcrun", "lipo", "-archs", str(binary)).split():
            temporary = binary.with_suffix(".thin")
            subprocess.run(["xcrun", "lipo", str(binary), "-remove", "arm64e",
                            "-output", str(temporary)], check=True)
            temporary.replace(binary)
        lib["SupportedArchitectures"] = run("xcrun", "lipo", "-archs", str(binary)).split()
        # Use the real deployment target, never relabel the SDK in the Mach-O.
        minimums = set(re.findall(r"\bminos\s+(\d+(?:\.\d+){1,2})",
                                 run("xcrun", "vtool", "-show-build", str(binary))))
        if len(minimums) != 1:
            raise ValueError(f"Missing or inconsistent deployment targets: {binary}")
        plist = framework / "Info.plist"
        if not plist.exists():
            plist = framework / "Resources/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["MinimumOSVersion"] = minimums.pop()
        plist.write_bytes(plistlib.dumps(info))
    metadata["AvailableLibraries"] = libraries
    (output / "Info.plist").write_bytes(plistlib.dumps(metadata))


if __name__ == "__main__":
    prepare(pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]))
