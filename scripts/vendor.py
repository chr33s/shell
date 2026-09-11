#!/usr/bin/env python3
"""Vendor every external Swift package under vendor/ and keep it in sync with
upstream.

    ./scripts/vendor.py sync [DIR...] [--force] [--commit]   # make vendor/ match vendor/manifest
    ./scripts/vendor.py update DIR REF [--commit]            # pin DIR to REF, then sync it
    ./scripts/vendor.py status                               # pinned vs newest upstream tag
    ./scripts/vendor.py localize [DIR...]                    # redo the manifest rewrite, no network
    ./scripts/vendor.py verify                               # offline consistency check (CI)

Model
-----
vendor/manifest is the single source of truth: one line per package with the
directory name, upstream git URL, the pinned tag (or commit), and options.
`sync` shallow-clones each pinned ref, replaces vendor/DIR wholesale with the
pristine upstream tree, and then *localizes* it:

  * every `.package(url:)` that points at another vendored package becomes
    `.package(path: "../DIR")`;
  * `.binaryTarget(url:checksum:)` entries named in `binaries=` are kept as
    they are — SwiftPM downloads the zip and verifies the upstream SHA-256, so
    the pin is content-addressed without committing the archive; unlisted
    binary targets (and the products that only exposed them) are removed;
  * dependencies named in `drop=` (and the targets that use them) are removed,
    so nothing outside vendor/ is ever resolved.

Because every local change is mechanical and re-derived on each sync, pulling
an upstream release is `update DIR REF` — there is nothing to merge. Hand
patches, if ever needed, live in vendor/patches/DIR/*.patch (plain `git diff`
output from the repository root) and are re-applied after localization; a
patch that no longer applies stops the sync so it can be rebased.

vendor/manifest.lock records the resolved commit and binary checksums and is
rewritten by `sync`; do not edit it by hand.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Dict, List, Optional, Tuple

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDOR = os.path.join(ROOT, "vendor")
MANIFEST = os.path.join(VENDOR, "manifest")
LOCK = os.path.join(VENDOR, "manifest.lock")
PATCHES = os.path.join(VENDOR, "patches")
BANNER = "// vendored by scripts/vendor.py — regenerated on every sync, do not edit by hand\n"


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #


def die(msg: str) -> "NoReturn":  # type: ignore[name-defined]
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def run(cmd: List[str], **kw) -> subprocess.CompletedProcess:
    kw.setdefault("check", True)
    kw.setdefault("text", True)
    return subprocess.run(cmd, **kw)


def git(*args: str, **kw) -> subprocess.CompletedProcess:
    return run(["git", "-C", ROOT, *args], **kw)


def identity(url: str) -> str:
    """SwiftPM package identity: last path component of the URL, lowercased,
    without a `.git` suffix."""
    tail = url.rstrip("/").rsplit("/", 1)[-1]
    if tail.endswith(".git"):
        tail = tail[:-4]
    return tail.lower()


class Package:
    def __init__(self, line_no: int, directory: str, url: str, ref: str, options: Dict[str, str]):
        self.line_no = line_no
        self.dir = directory
        self.url = url
        self.ref = ref
        self.options = options

    @property
    def path(self) -> str:
        return os.path.join(VENDOR, self.dir)

    @property
    def binaries(self) -> List[str]:
        v = self.options.get("binaries", "")
        return [b for b in v.split(",") if b]

    @property
    def drops(self) -> List[str]:
        v = self.options.get("drop", "")
        return [d.lower() for d in v.split(",") if d]

    @property
    def identity(self) -> str:
        return identity(self.url)


def read_manifest() -> List[Package]:
    if not os.path.exists(MANIFEST):
        die(f"{os.path.relpath(MANIFEST, ROOT)} not found")
    packages: List[Package] = []
    seen = set()
    with open(MANIFEST) as f:
        for n, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            cols = line.split()
            if len(cols) < 3:
                die(f"manifest line {n}: expected `DIR URL REF [key=value ...]`")
            directory, url, ref = cols[:3]
            if "/" in directory or directory in (".", ".."):
                die(f"manifest line {n}: bad directory name {directory!r}")
            if directory in seen:
                die(f"manifest line {n}: duplicate package {directory}")
            seen.add(directory)
            options: Dict[str, str] = {}
            for tok in cols[3:]:
                if "=" not in tok:
                    die(f"manifest line {n}: option {tok!r} must be key=value")
                k, v = tok.split("=", 1)
                options[k] = v
            packages.append(Package(n, directory, url, ref, options))
    return packages


def read_lock() -> Dict[str, dict]:
    if not os.path.exists(LOCK):
        return {}
    with open(LOCK) as f:
        return json.load(f)


def write_lock(lock: Dict[str, dict]) -> None:
    with open(LOCK, "w") as f:
        json.dump(dict(sorted(lock.items())), f, indent=2, sort_keys=True)
        f.write("\n")


def select(packages: List[Package], names: List[str]) -> List[Package]:
    if not names:
        return packages
    by_dir = {p.dir: p for p in packages}
    missing = [n for n in names if n not in by_dir]
    if missing:
        die(f"not in manifest: {', '.join(missing)}")
    return [by_dir[n] for n in names]


# --------------------------------------------------------------------------- #
# Package.swift rewriting
# --------------------------------------------------------------------------- #


def _skip_string(text: str, i: int) -> int:
    """i points at an opening quote; return index just past the closing one."""
    if text.startswith('"""', i):
        j = text.find('"""', i + 3)
        return len(text) if j < 0 else j + 3
    j = i + 1
    while j < len(text):
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == '"':
            return j + 1
        j += 1
    return j


def find_calls(text: str, name: str) -> List[Tuple[int, int]]:
    """Spans of every `.NAME( ... )` call, parens balanced, strings and line
    comments skipped."""
    spans: List[Tuple[int, int]] = []
    needle = "." + name + "("
    i = 0
    while True:
        i = text.find(needle, i)
        if i < 0:
            return spans
        # make sure we matched a whole identifier
        if i > 0 and (text[i - 1].isalnum() or text[i - 1] == "_"):
            i += 1
            continue
        depth = 0
        j = i + len(needle) - 1
        while j < len(text):
            c = text[j]
            if c == '"':
                j = _skip_string(text, j)
                continue
            if text.startswith("//", j):
                j = text.find("\n", j)
                if j < 0:
                    j = len(text)
                continue
            if text.startswith("/*", j):
                j = text.find("*/", j + 2)
                j = len(text) if j < 0 else j + 2
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    spans.append((i, j + 1))
                    break
            j += 1
        i = j


def arg_string(span_text: str, label: str) -> Optional[str]:
    m = re.search(r'(?<![A-Za-z0-9_])' + re.escape(label) + r'\s*:\s*"((?:[^"\\]|\\.)*)"', span_text)
    return m.group(1) if m else None


def remove_element(text: str, start: int, end: int) -> str:
    """Delete an array element (a call span) and its separating comma, taking
    the whole line with it when nothing else is on it."""
    # swallow a trailing comma
    k = end
    while k < len(text) and text[k] in " \t":
        k += 1
    if k < len(text) and text[k] == ",":
        end = k + 1
    # take the trailing newline if the rest of the line is blank
    k = end
    while k < len(text) and text[k] in " \t":
        k += 1
    if k < len(text) and text[k] == "\n":
        end = k + 1
    # take leading indentation if the element starts its line
    s = start
    while s > 0 and text[s - 1] in " \t":
        s -= 1
    if s == 0 or text[s - 1] == "\n":
        start = s
    return text[:start] + text[end:]


def rewrite_targets_list(text: str, removed: List[str]) -> str:
    """Drop removed target names from `targets: [...]` arrays and remove any
    product whose target list would become empty."""
    if not removed:
        return text
    removed_set = set(removed)
    for product_kind in ("library", "executable", "plugin"):
        for start, end in reversed(find_calls(text, product_kind)):
            span = text[start:end]
            m = re.search(r"targets\s*:\s*\[([^\]]*)\]", span)
            if not m:
                continue
            names = re.findall(r'"((?:[^"\\]|\\.)*)"', m.group(1))
            keep = [n for n in names if n not in removed_set]
            if len(keep) == len(names):
                continue
            if not keep:
                text = remove_element(text, start, end)
                continue
            new_list = "targets: [" + ", ".join(f'"{n}"' for n in keep) + "]"
            span = span[: m.start()] + new_list + span[m.end():]
            text = text[:start] + span + text[end:]
    return text


def collect_binaries(package_dir: str) -> Dict[str, Tuple[str, str]]:
    """name -> (url, checksum) for every remote binary target in the pristine
    manifests of a package."""
    found: Dict[str, Tuple[str, str]] = {}
    for manifest in manifests_in(package_dir):
        text = open(manifest).read()
        for start, end in find_calls(text, "binaryTarget"):
            span = text[start:end]
            name, url, checksum = arg_string(span, "name"), arg_string(span, "url"), arg_string(span, "checksum")
            if name and url and checksum:
                found[name] = (url, checksum)
    return found


def manifests_in(package_dir: str) -> List[str]:
    return sorted(
        os.path.join(package_dir, f)
        for f in os.listdir(package_dir)
        if f == "Package.swift" or (f.startswith("Package@swift-") and f.endswith(".swift"))
    )


def localize_text(text: str, pkg: Package, by_identity: Dict[str, Package], rel: str) -> str:
    """Rewrite one manifest. `rel` is used in error messages."""
    removed_targets: List[str] = []

    # 1. dependencies
    for start, end in reversed(find_calls(text, "package")):
        span = text[start:end]
        url = arg_string(span, "url")
        if url is None:
            continue  # already a path dependency
        ident = identity(url)
        if ident in pkg.drops:
            text = remove_element(text, start, end)
            continue
        target = by_identity.get(ident)
        if target is None:
            die(
                f"{rel}: depends on {url}, which is not vendored.\n"
                f"  Add it to vendor/manifest, or drop it with `drop={ident}` on the {pkg.dir} line."
            )
        if target.dir == pkg.dir:
            die(f"{rel}: package depends on itself via {url}")
        name = arg_string(span, "name")
        head = f'.package(name: "{name}", ' if name else ".package("
        text = text[:start] + head + f'path: "../{target.dir}")' + text[end:]

    # 2. targets that consumed a dropped dependency
    if pkg.drops:
        for kind in ("target", "executableTarget", "testTarget", "macro", "plugin"):
            for start, end in reversed(find_calls(text, kind)):
                span = text[start:end]
                uses = re.findall(r'package\s*:\s*"((?:[^"\\]|\\.)*)"', span)
                if any(u.lower() in pkg.drops for u in uses):
                    name = arg_string(span, "name")
                    if name:
                        removed_targets.append(name)
                    text = remove_element(text, start, end)

    # 3. binary targets: keep the checksum-pinned ones we link, drop the rest
    for start, end in reversed(find_calls(text, "binaryTarget")):
        span = text[start:end]
        name = arg_string(span, "name")
        if arg_string(span, "url") is None or name is None or name in pkg.binaries:
            continue
        removed_targets.append(name)
        text = remove_element(text, start, end)

    text = rewrite_targets_list(text, removed_targets)

    # 4. banner, after the swift-tools-version line
    if BANNER not in text:
        nl = text.find("\n")
        text = text[: nl + 1] + BANNER + text[nl + 1 :]
    return text


def localize_package(pkg: Package, packages: List[Package]) -> None:
    by_identity = {p.identity: p for p in packages}
    for manifest in manifests_in(pkg.path):
        rel = os.path.relpath(manifest, ROOT)
        original = open(manifest).read()
        rewritten = localize_text(original, pkg, by_identity, rel)
        if rewritten != original:
            with open(manifest, "w") as f:
                f.write(rewritten)


def apply_patches(pkg: Package) -> None:
    patch_dir = os.path.join(PATCHES, pkg.dir)
    if not os.path.isdir(patch_dir):
        return
    for patch in sorted(os.listdir(patch_dir)):
        if not patch.endswith(".patch"):
            continue
        full = os.path.join(patch_dir, patch)
        res = git("apply", "--check", full, check=False, capture_output=True)
        if res.returncode != 0:
            die(
                f"{os.path.relpath(full, ROOT)} no longer applies to {pkg.dir} {pkg.ref}:\n{res.stderr.strip()}\n"
                f"  Rebase the patch (or delete it) and re-run `scripts/vendor.py localize {pkg.dir}`."
            )
        git("apply", full)
        print(f"  patch   {patch}")


# --------------------------------------------------------------------------- #
# fetching
# --------------------------------------------------------------------------- #


def shallow_clone(pkg: Package, dest: str) -> str:
    """Clone the pinned ref (tag, branch, or commit) with depth 1; return its
    commit hash. Submodules are deliberately not fetched."""
    res = run(
        ["git", "clone", "--quiet", "--depth", "1", "--branch", pkg.ref, "--", pkg.url, dest],
        check=False,
        capture_output=True,
    )
    if res.returncode != 0:
        shutil.rmtree(dest, ignore_errors=True)
        if not re.fullmatch(r"[0-9a-f]{7,40}", pkg.ref):
            die(f"{pkg.dir}: cannot fetch {pkg.ref} from {pkg.url}\n{res.stderr.strip()}")
        os.makedirs(dest)
        run(["git", "-C", dest, "init", "--quiet"])
        run(["git", "-C", dest, "fetch", "--quiet", "--depth", "1", pkg.url, pkg.ref])
        run(["git", "-C", dest, "checkout", "--quiet", "FETCH_HEAD"])
    commit = run(["git", "-C", dest, "rev-parse", "HEAD"], capture_output=True).stdout.strip()
    shutil.rmtree(os.path.join(dest, ".git"))
    return commit


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #


def dirty(path_in_repo: str) -> bool:
    res = git("status", "--porcelain", "--", path_in_repo, capture_output=True)
    return bool(res.stdout.strip())


def sync_package(pkg: Package, packages: List[Package], lock: Dict[str, dict], force: bool) -> bool:
    """Returns True when vendor/DIR changed."""
    entry = lock.get(pkg.dir, {})
    if os.path.isdir(pkg.path) and dirty(os.path.relpath(pkg.path, ROOT)) and not force:
        die(f"vendor/{pkg.dir} has uncommitted changes; commit or discard them, or pass --force")

    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "src")
        print(f"fetch   {pkg.dir} {pkg.ref}")
        commit = shallow_clone(pkg, src)
        if (
            not force
            and os.path.isdir(pkg.path)
            and entry.get("commit") == commit
            and entry.get("ref") == pkg.ref
            and sorted(entry.get("binaries", {})) == sorted(pkg.binaries)
            and entry.get("drop", []) == pkg.drops
        ):
            print(f"ok      {pkg.dir} already at {commit[:12]}")
            return False

        upstream_binaries = collect_binaries(src)
        missing = [b for b in pkg.binaries if b not in upstream_binaries]
        if missing:
            die(f"{pkg.dir}: no remote binary target named {', '.join(missing)} in upstream Package.swift")
        new_binaries = {
            name: {"url": upstream_binaries[name][0], "checksum": upstream_binaries[name][1]}
            for name in pkg.binaries
        }

        if os.path.isdir(pkg.path):
            shutil.rmtree(pkg.path)
        os.makedirs(VENDOR, exist_ok=True)
        shutil.move(src, pkg.path)

    localize_package(pkg, packages)
    apply_patches(pkg)
    lock[pkg.dir] = {
        "url": pkg.url,
        "ref": pkg.ref,
        "commit": commit,
        "binaries": new_binaries,
        "drop": pkg.drops,
    }
    print(f"vendored {pkg.dir} {pkg.ref} ({commit[:12]})")
    return True


def stage(pkg: Package) -> None:
    git("add", "--all", "--force", "--", os.path.relpath(pkg.path, ROOT))
    git("add", "--", os.path.relpath(MANIFEST, ROOT), os.path.relpath(LOCK, ROOT))


def cmd_sync(args: argparse.Namespace) -> None:
    packages = read_manifest()
    lock = read_lock()
    changed: List[Package] = []
    for pkg in select(packages, args.packages):
        if sync_package(pkg, packages, lock, args.force):
            changed.append(pkg)
        write_lock(lock)
    # A package that was already current may still need re-localizing when a
    # sibling it points at was renamed or added.
    for pkg in select(packages, args.packages):
        if pkg not in changed and os.path.isdir(pkg.path):
            localize_package(pkg, packages)
    # Packages removed from the manifest are pruned.
    stale = [d for d in lock if d not in {p.dir for p in packages}]
    for d in stale:
        path = os.path.join(VENDOR, d)
        if os.path.isdir(path):
            shutil.rmtree(path)
            git("add", "--all", "--", os.path.relpath(path, ROOT), check=False)
        del lock[d]
        print(f"removed {d} (no longer in manifest)")
    write_lock(lock)
    for pkg in changed:
        stage(pkg)
        if args.commit:
            git("commit", "--quiet", "-m", f"vendor: {pkg.dir} {pkg.ref}", "--", os.path.relpath(pkg.path, ROOT),
                os.path.relpath(MANIFEST, ROOT), os.path.relpath(LOCK, ROOT))
            print(f"committed vendor: {pkg.dir} {pkg.ref}")
    if changed and not args.commit:
        print(f"{len(changed)} package(s) staged; review with `git diff --cached --stat` and commit.")


def cmd_update(args: argparse.Namespace) -> None:
    packages = read_manifest()
    pkg = select(packages, [args.package])[0]
    lines = open(MANIFEST).read().split("\n")
    line = lines[pkg.line_no - 1]
    new_line = re.sub(r"^(\s*\S+\s+\S+\s+)" + re.escape(pkg.ref), lambda m: m.group(1) + args.ref, line, count=1)
    if new_line == line and pkg.ref != args.ref:
        die(f"could not rewrite manifest line {pkg.line_no}")
    lines[pkg.line_no - 1] = new_line
    with open(MANIFEST, "w") as f:
        f.write("\n".join(lines))
    print(f"manifest: {pkg.dir} {pkg.ref} -> {args.ref}")
    args.packages = [pkg.dir]
    args.force = False
    cmd_sync(args)


def semver_key(tag: str) -> Optional[Tuple[int, ...]]:
    m = re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)", tag)
    return tuple(int(x) for x in m.groups()) if m else None


def cmd_status(args: argparse.Namespace) -> None:
    packages = read_manifest()
    lock = read_lock()
    rows = []
    for pkg in packages:
        res = run(["git", "ls-remote", "--tags", "--refs", pkg.url], check=False, capture_output=True)
        latest = "?"
        if res.returncode == 0:
            tags = [l.split("refs/tags/", 1)[1] for l in res.stdout.splitlines() if "refs/tags/" in l]
            stable = [(semver_key(t), t) for t in tags if semver_key(t)]
            if stable:
                latest = max(stable)[1]
        entry = lock.get(pkg.dir, {})
        commit = entry.get("commit", "")[:12] or "-"
        state = "ok"
        if not os.path.isdir(pkg.path):
            state = "MISSING"
        elif entry.get("ref") != pkg.ref:
            state = "STALE (run sync)"
        elif latest != "?" and semver_key(latest) and semver_key(pkg.ref) and semver_key(latest) > semver_key(pkg.ref):
            state = f"update available: {latest}"
        rows.append((pkg.dir, pkg.ref, commit, latest, state))
    w = [max(len(r[i]) for r in rows + [("package", "pinned", "commit", "newest", "state")]) for i in range(5)]
    fmt = "  ".join("{:<%d}" % x for x in w)
    print(fmt.format("package", "pinned", "commit", "newest", "state"))
    for r in rows:
        print(fmt.format(*r))


def cmd_localize(args: argparse.Namespace) -> None:
    packages = read_manifest()
    for pkg in select(packages, args.packages):
        if not os.path.isdir(pkg.path):
            die(f"vendor/{pkg.dir} is missing; run `scripts/vendor.py sync {pkg.dir}`")
        localize_package(pkg, packages)
        apply_patches(pkg)
        print(f"localized {pkg.dir}")


def cmd_verify(args: argparse.Namespace) -> None:
    packages = read_manifest()
    lock = read_lock()
    problems: List[str] = []
    by_identity = {p.identity: p for p in packages}
    for pkg in packages:
        entry = lock.get(pkg.dir)
        if not os.path.isdir(pkg.path):
            problems.append(f"vendor/{pkg.dir} is missing")
            continue
        if not entry:
            problems.append(f"{pkg.dir} is not in manifest.lock")
        elif entry.get("ref") != pkg.ref or entry.get("url") != pkg.url:
            problems.append(f"{pkg.dir}: manifest pins {pkg.ref} but lock has {entry.get('ref')}")
        for manifest in manifests_in(pkg.path):
            text = open(manifest).read()
            rel = os.path.relpath(manifest, ROOT)
            for start, end in find_calls(text, "package"):
                url = arg_string(text[start:end], "url")
                if url is not None:
                    problems.append(f"{rel}: still resolves {url} remotely")
                path = arg_string(text[start:end], "path")
                if path is not None:
                    target = os.path.normpath(os.path.join(pkg.path, path))
                    if not os.path.isdir(target):
                        problems.append(f"{rel}: path dependency {path} does not exist")
            for start, end in find_calls(text, "binaryTarget"):
                span = text[start:end]
                name = arg_string(span, "name")
                if arg_string(span, "url") is not None and name not in pkg.binaries:
                    problems.append(f"{rel}: binary target {name} is not listed in binaries=")
                if arg_string(span, "url") is not None and arg_string(span, "checksum") is None:
                    problems.append(f"{rel}: binary target {name} has no checksum")
    for d in lock:
        if d not in {p.dir for p in packages}:
            problems.append(f"lock entry {d} has no manifest line")
    for d in sorted(os.listdir(VENDOR)) if os.path.isdir(VENDOR) else []:
        if os.path.isdir(os.path.join(VENDOR, d)) and d != "patches" and d not in {p.dir for p in packages}:
            problems.append(f"vendor/{d} is not in the manifest")
    if problems:
        for p in problems:
            print(f"  {p}")
        die(f"{len(problems)} problem(s); run `scripts/vendor.py sync`")
    print(f"vendor: {len(packages)} packages consistent")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("sync", help="make vendor/ match vendor/manifest")
    p.add_argument("packages", nargs="*")
    p.add_argument("--force", action="store_true", help="re-vendor even if already current or dirty")
    p.add_argument("--commit", action="store_true", help="commit each changed package")
    p.set_defaults(fn=cmd_sync)

    p = sub.add_parser("update", help="pin a package to a new ref and sync it")
    p.add_argument("package")
    p.add_argument("ref")
    p.add_argument("--commit", action="store_true")
    p.set_defaults(fn=cmd_update)

    p = sub.add_parser("status", help="compare pins with the newest upstream tags")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("localize", help="re-apply manifest rewrites and patches without fetching")
    p.add_argument("packages", nargs="*")
    p.set_defaults(fn=cmd_localize)

    p = sub.add_parser("verify", help="offline consistency check")
    p.set_defaults(fn=cmd_verify)

    args = ap.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
