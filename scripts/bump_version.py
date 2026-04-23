#!/usr/bin/env python3
"""
Version Bump Script for Axion-Common

Manages the .version file for the project:
- Reads / writes version  (format: <major>.<minor>.<patch>)
- Can auto-bump version based on bump type

Usage:
    python scripts/bump_version.py                  # Print current version
    python scripts/bump_version.py --bump minor     # Bump minor, reset patch to 0
    python scripts/bump_version.py --bump patch     # Bump patch
    python scripts/bump_version.py --bump major     # Bump major, reset minor+patch to 0
    python scripts/bump_version.py --check          # Validate .version and print
"""

import argparse
import re
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).parent.parent
VERSION_FILE = PROJECT_ROOT / ".version"


# ---------------------------------------------------------------------------
# Core helpers
# ---------------------------------------------------------------------------

def parse_version(version_str: str) -> tuple:
    """Parse '<major>.<minor>.<patch>' (with optional leading v) into a tuple."""
    version_str = version_str.strip().lstrip("v")
    match = re.match(r"^(\d+)\.(\d+)\.(\d+)$", version_str)
    if not match:
        raise ValueError(f"Invalid version format: '{version_str}' — expected X.Y.Z")
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def format_version(major: int, minor: int, patch: int) -> str:
    return f"{major}.{minor}.{patch}"


def read_version() -> str:
    """Return the raw contents of .version (stripped)."""
    if not VERSION_FILE.exists():
        raise FileNotFoundError(f".version file not found at {VERSION_FILE}")
    return VERSION_FILE.read_text().strip()


def write_version(version: str) -> None:
    VERSION_FILE.write_text(version + "\n")


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

def bump_version(bump_type: str) -> str:
    """Bump the version in .version and return the new version string."""
    current = read_version()
    major, minor, patch = parse_version(current)

    if bump_type == "major":
        major += 1
        minor = 0
        patch = 0
    elif bump_type == "minor":
        minor += 1
        patch = 0
    elif bump_type == "patch":
        patch += 1
    else:
        raise ValueError(f"Invalid bump type: '{bump_type}' — expected major/minor/patch")

    new_version = format_version(major, minor, patch)
    write_version(new_version)
    return new_version


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Version bump tool for Axion-Common",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "--bump",
        choices=["major", "minor", "patch"],
        help="Bump the specified version component and write the new value to .version",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Validate that .version exists and contains a valid semver string",
    )
    args = parser.parse_args()

    if args.check:
        version = read_version()
        parse_version(version)  # raises on invalid format
        print(f"✓ .version is valid: {version}")
        return 0

    if args.bump:
        new_version = bump_version(args.bump)
        print(f"Bumped to: {new_version}")
        return 0

    # Default: just print the current version
    print(read_version())
    return 0


if __name__ == "__main__":
    sys.exit(main())
