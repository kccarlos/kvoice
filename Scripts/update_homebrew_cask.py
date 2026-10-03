#!/usr/bin/env python3
"""Point the Homebrew cask at a released version.

The tap (github.com/kccarlos/homebrew-tap) holds one cask, Casks/kvoice.rb,
whose download URL is built from `version`. A release changes exactly two
lines of it, and this script rewrites exactly those two:

    version "X.Y.Z"
    sha256 "<64 hex digits>"

Usage:

    update_homebrew_cask.py <cask.rb> <version> --sha256 <hex>
    update_homebrew_cask.py <cask.rb> <version> --sha256-file <KVoice-X.Y.Z.dmg.sha256>

The release workflow's `homebrew` job runs it with the `.sha256` file that
was published next to the DMG; a person updating the tap by hand can run it
the same way (the release documentation).

It refuses, changing nothing (exit 2): a version that is not
MAJOR.MINOR.PATCH (a pre-release never goes to the tap), a checksum that is
not 64 hex digits, a `.sha256` file whose file name is not
KVoice-<version>.dmg, a cask without exactly one `version` and one `sha256`
line, and a version older than the cask's (a later patch of an older line
would otherwise replace the newest release; `--allow-downgrade` overrides).
Running it again with the same input changes nothing and says so (exit 0).
Standard library only.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

VERSION = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
SHA256 = re.compile(r"[0-9a-f]{64}")
VERSION_LINE = re.compile(r'^(?P<indent>[ \t]*)version "(?P<value>[^"\n]*)"[ \t]*$', re.MULTILINE)
SHA256_LINE = re.compile(r'^(?P<indent>[ \t]*)sha256 "(?P<value>[^"\n]*)"[ \t]*$', re.MULTILINE)


class Refused(Exception):
    pass


def checksum_from_file(path: Path, version: str) -> str:
    """The digest from a `shasum -a 256` line for KVoice-<version>.dmg."""
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise Refused(f"cannot read {path}: {error.strerror}") from None
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        raise Refused(f"{path} must hold exactly one checksum line")
    fields = lines[0].split()
    if len(fields) != 2:
        raise Refused(f"{path} is not '<sha256>  <file>'")
    digest, name = fields
    expected = f"KVoice-{version}.dmg"
    if name.lstrip("*") != expected:
        raise Refused(f"{path} is the checksum of {name}, not {expected}")
    return digest.lower()


def as_tuple(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in version.split("."))


def rewrite(cask: str, version: str, digest: str, allow_downgrade: bool = False) -> str:
    """The cask with `version` and `sha256` replaced; raises Refused."""
    if not VERSION.fullmatch(version):
        raise Refused(f"version '{version}' is not MAJOR.MINOR.PATCH")
    if not SHA256.fullmatch(digest):
        raise Refused("the checksum is not 64 hex digits")

    versions = list(VERSION_LINE.finditer(cask))
    digests = list(SHA256_LINE.finditer(cask))
    if len(versions) != 1:
        raise Refused(f"the cask has {len(versions)} `version \"…\"` lines, not one")
    if len(digests) != 1:
        raise Refused(f"the cask has {len(digests)} `sha256 \"…\"` lines, not one")

    current = versions[0].group("value")
    if VERSION.fullmatch(current) and as_tuple(version) < as_tuple(current) and not allow_downgrade:
        raise Refused(f"version {version} is older than the cask's {current} (--allow-downgrade to force)")

    cask = VERSION_LINE.sub(lambda m: f'{m.group("indent")}version "{version}"', cask, count=1)
    return SHA256_LINE.sub(lambda m: f'{m.group("indent")}sha256 "{digest}"', cask, count=1)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Point the KVoice Homebrew cask at a released version.")
    parser.add_argument("cask", type=Path, help="Casks/kvoice.rb in a clone of the tap")
    parser.add_argument("version", help="the released version, MAJOR.MINOR.PATCH")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--sha256", help="the DMG's SHA-256, 64 hex digits")
    source.add_argument("--sha256-file", type=Path, help="the KVoice-<version>.dmg.sha256 file from the release")
    parser.add_argument("--allow-downgrade", action="store_true", help="accept a version older than the cask's")
    args = parser.parse_args(argv)

    try:
        digest = checksum_from_file(args.sha256_file, args.version) if args.sha256_file else args.sha256.lower()
        try:
            original = args.cask.read_text(encoding="utf-8")
        except OSError as error:
            raise Refused(f"cannot read {args.cask}: {error.strerror}") from None
        updated = rewrite(original, args.version, digest, args.allow_downgrade)
    except Refused as error:
        print(f"update_homebrew_cask: {error}", file=sys.stderr)
        return 2

    if updated == original:
        print(f"update_homebrew_cask: {args.cask} is already at {args.version}; unchanged")
        return 0
    args.cask.write_text(updated, encoding="utf-8")
    print(f"update_homebrew_cask: {args.cask} now at {args.version}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
