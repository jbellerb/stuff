#!/usr/bin/env python3

import argparse
import base64
import hashlib
import sys
import urllib.request
from pathlib import Path

import tomllib

PACKAGES_DIR = Path(__file__).resolve().parent

CHUNK_SIZE = 64 * 1024


def fetch_sri_hash(url: str) -> str:
    print(f"Fetching {url}", file=sys.stderr)
    sha = hashlib.sha256()
    with urllib.request.urlopen(url, timeout=30) as response:
        while chunk := response.read(CHUNK_SIZE):
            sha.update(chunk)
    return f"sha256-{base64.b64encode(sha.digest()).decode('ascii')}"


def update_file(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    data = tomllib.loads(text)

    bins = data.get("bin")
    if not isinstance(bins, list):
        raise TypeError(f"{path} does not contain a [[bin]] array")

    delta: dict[str, str] = {}
    for entry in bins:
        if not isinstance(entry, dict):
            raise TypeError(f"{path} contains a non-table [[bin]] entry")

        url = entry.get("url")
        if not isinstance(url, str):
            raise TypeError(f"{path} has a [[bin]] entry without a string url")

        old_hash = entry.get("hash")
        if not isinstance(old_hash, str):
            raise TypeError(f"{path} has a [[bin]] entry without a string hash")

        if old_hash not in delta:
            new_hash = fetch_sri_hash(url)
            if old_hash != new_hash:
                delta[old_hash] = new_hash

    for old_hash, new_hash in delta.items():
        if (occurrences := text.count(old_hash)) != 1:
            raise ValueError(
                f"Old hash {old_hash!s} is ambiguous in {path}: found {occurrences} occurrences"
            )

        text = text.replace(old_hash, new_hash)

    if delta:
        path.write_text(text, encoding="utf-8")

    return len(delta)


def default_paths() -> list[Path]:
    return sorted(PACKAGES_DIR.glob("*.toml"))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Update sha256 SRI hashes in nix/packages TOML files"
    )
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        help="TOML files to update (defaults to nix/packages/*.toml)",
    )
    args = parser.parse_args()

    paths = args.paths or default_paths()
    if not paths:
        raise FileNotFoundError(f"No TOML files found in {PACKAGES_DIR}")

    total_updated = 0
    total_files = 0
    for path in paths:
        updated = update_file(path)
        if updated > 0:
            total_updated += updated
            total_files += 1
            print(
                f"Updated {path} ({updated} hash{'es' if updated != 1 else ''})",
                file=sys.stderr,
            )
        else:
            print(f"Skipping {path} (already up to date)", file=sys.stderr)

    print(
        f"Updated {total_updated} hash{'es' if total_updated != 1 else ''} in {total_files} file{'s' if total_files != 1 else ''}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
