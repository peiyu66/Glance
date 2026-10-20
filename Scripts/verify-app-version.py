#!/usr/bin/env python3
"""Reject missing, malformed, or mismatched version metadata in a built app."""

import argparse
import plistlib
import re
import sys
from pathlib import Path


VERSION_PATTERN = r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
BUILD_PATTERN = r"[1-9][0-9]*"


def validate_value(value, name, pattern):
    if not isinstance(value, str) or not value:
        raise ValueError(f"{name} must be a nonempty string")
    if re.fullmatch(pattern, value) is None:
        raise ValueError(f"{name} has an invalid format: {value!r}")


def validate_info(info, expected_version, expected_build):
    validate_value(expected_version, "MARKETING_VERSION", VERSION_PATTERN)
    validate_value(expected_build, "CURRENT_PROJECT_VERSION", BUILD_PATTERN)
    if not isinstance(info, dict):
        raise ValueError("Info.plist must contain a dictionary")
    for key, expected, pattern in (
        ("CFBundleShortVersionString", expected_version, VERSION_PATTERN),
        ("CFBundleVersion", expected_build, BUILD_PATTERN),
    ):
        actual = info.get(key)
        validate_value(actual, key, pattern)
        if actual != expected:
            raise ValueError(f"{key} is {actual!r}; expected {expected!r}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("plist", type=Path, help="Generated app Info.plist")
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-build", required=True)
    args = parser.parse_args()
    try:
        with args.plist.open("rb") as source:
            info = plistlib.load(source)
        validate_info(info, args.expected_version, args.expected_build)
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException) as error:
        print(f"error: Glance version metadata: {error}", file=sys.stderr)
        return 1
    print(f"Verified Glance version {args.expected_version} (Build {args.expected_build}).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
