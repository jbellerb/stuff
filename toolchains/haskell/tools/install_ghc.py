#!/usr/bin/env python3

import argparse
import os
import shutil
import subprocess
from pathlib import Path


def _repo_path(repo_root: Path, path: str) -> Path:
    candidate = Path(path)
    if candidate.is_absolute():
        return candidate
    return repo_root / candidate


def _tool_path(repo_root: Path, scratch_root: Path, path: str) -> str:
    candidate = Path(path)
    if candidate.is_absolute():
        return path
    if (repo_root / candidate).exists():
        return str(scratch_root / candidate)
    return path


def _symlink_relative(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.is_symlink() or dst.exists():
        dst.unlink()
    dst.symlink_to(
        os.path.relpath(src, start=dst.parent), target_is_directory=src.is_dir()
    )


def main() -> int:
    parser = argparse.ArgumentParser()

    parser.add_argument("--bindist", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--cc", required=True)
    parser.add_argument("--cxx", required=True)
    parser.add_argument("--ld", required=True)
    parser.add_argument("--ar", required=True)
    parser.add_argument("--nm", required=True)
    parser.add_argument("--ranlib", required=True)
    parser.add_argument("--cflags", required=False)
    parser.add_argument("--cxxflags", required=False)
    parser.add_argument("--linkflags", required=False)
    parser.add_argument("--bin-prefix", dest="bin_prefix", default="")
    parser.add_argument("--host-triple", dest="host_triple", required=True)
    parser.add_argument("--target-triple", dest="target_triple", required=True)

    args = parser.parse_args()

    repo_root = Path.cwd()
    scratch_dir = repo_root / Path(os.environ["BUCK_SCRATCH_PATH"])
    scratch_dir.mkdir(parents=True, exist_ok=True)
    scratch_root = scratch_dir / "root"
    _symlink_relative(repo_root, scratch_root)

    bindist = _repo_path(repo_root, args.bindist)
    out_dir = _repo_path(repo_root, args.out)
    cc = _tool_path(repo_root, scratch_root, args.cc)

    subprocess.run(
        [
            str(bindist / "configure"),
            f"--srcdir={bindist}",
            f"--prefix={out_dir}",
            f"--build={args.host_triple}",
            f"--host={args.host_triple}",
            f"--target={args.target_triple}",
        ],
        cwd=scratch_dir,
        env={
            "PATH": os.environ["PATH"],
            "AR": _tool_path(repo_root, scratch_root, args.ar),
            "CC": cc,
            "CPP": f"{cc} -E",
            "CXX": _tool_path(repo_root, scratch_root, args.cxx),
            "LD": _tool_path(repo_root, scratch_root, args.ld),
            "NM": _tool_path(repo_root, scratch_root, args.nm),
            "RANLIB": _tool_path(repo_root, scratch_root, args.ranlib),
        },
        check=True,
    )

    config_mk = scratch_dir / "config.mk"
    strip_prefix = f"{repo_root / scratch_root}{os.sep}"
    config_mk.write_text(
        config_mk.read_text(encoding="utf-8").replace(strip_prefix, ""),
        encoding="utf-8",
    )

    (scratch_dir / "lib").mkdir(exist_ok=True)
    make = [
        "make",
        f"--file={bindist / 'Makefile'}",
        f"--include-dir={bindist}",
        "lib/settings",
    ]
    if args.cflags:
        make.append(f"SettingsCCompilerFlags={args.cflags}")
    if args.cxxflags:
        make.append(f"SettingsCxxCompilerFlags={args.cxxflags}")
    if args.linkflags:
        make.append(f"SettingsCCompilerLinkFlags={args.linkflags}")
    subprocess.run(
        make,
        cwd=scratch_dir,
        check=True,
    )

    (out_dir / "lib").mkdir(parents=True, exist_ok=True)
    shutil.move(str(scratch_dir / "lib" / "settings"), out_dir / "lib" / "settings")

    ghc_pkg = str(bindist / "bin" / (args.bin_prefix + "ghc-pkg"))
    package_db = out_dir / "lib" / "package.conf.d"
    subprocess.run([ghc_pkg, "init", str(package_db)], cwd=repo_root, check=True)

    # create a stub package database with only rts. The rest of the boot
    # packages will be linked explicitly.
    for target in sorted((bindist / "lib").glob("*-ghc-*")):
        pkg_path = out_dir / "lib" / target.name
        pkg_path.mkdir(parents=True, exist_ok=True)
        for path in sorted((bindist / "lib" / target.name).glob("rts-*")):
            _symlink_relative(path, pkg_path / path.name)
        for path in sorted((bindist / "lib" / target.name).glob("libHSrts-*")):
            _symlink_relative(path, pkg_path / path.name)
    for path in sorted((bindist / "lib" / "package.conf.d").glob("rts-*.conf")):
        shutil.copy2(path, package_db / path.name)

    subprocess.run(
        [
            ghc_pkg,
            "--package-db",
            str(package_db),
            "--no-user-package-db",
            "recache",
        ],
        cwd=repo_root,
        check=True,
    )

    _symlink_relative(bindist / "include", out_dir / "include")

    (out_dir / "bin").mkdir(parents=True, exist_ok=True)
    for path in sorted((bindist / "bin").iterdir()):
        _symlink_relative(path, out_dir / "bin" / path.name)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
