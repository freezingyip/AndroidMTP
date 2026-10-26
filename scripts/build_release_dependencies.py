#!/usr/bin/env python3
"""Build the bundled USB libraries with the app's macOS 13 deployment target."""
import hashlib
import json
import os
import shutil
import subprocess
import tarfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / ".build/release-dependencies"
PREFIX = WORK / "install"


def main():
    manifests = json.loads((ROOT / "docs/dependencies.json").read_text())
    environment = os.environ.copy()
    environment["MACOSX_DEPLOYMENT_TARGET"] = "13.0"
    environment["CFLAGS"] = "-O2 -mmacosx-version-min=13.0 -Werror=unguarded-availability-new"
    environment["CXXFLAGS"] = environment["CFLAGS"]
    environment["LDFLAGS"] = "-mmacosx-version-min=13.0"
    environment["lt_cv_sys_max_cmd_len"] = "262144"
    # The macOS 27 SDK declares pipe2; use the existing pipe/fcntl fallback on 13+.
    environment["ac_cv_func_pipe2"] = "no"
    environment["PKG_CONFIG_PATH"] = str(PREFIX / "lib/pkgconfig")
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + environment["PATH"]
    WORK.mkdir(parents=True, exist_ok=True)
    # The same verified source archives accompany the GitHub downloads.
    for name in ("libusb", "libmtp"):
        dependency = next(item for item in manifests if item["name"] == name)
        candidates = sorted((ROOT / "build/release").glob(f"*/dependency-sources/{dependency['archive']}"))
        if not candidates:
            raise SystemExit(f"Download {dependency['url']} to build/release/<version>/dependency-sources/")
        archive = candidates[-1]
        if hashlib.sha256(archive.read_bytes()).hexdigest() != dependency["sha256"]:
            raise SystemExit(f"Source checksum mismatch: {archive}")
        source = WORK / f"{name}-{dependency['version']}"
        if source.exists():
            shutil.rmtree(source)
        with tarfile.open(archive) as compressed:
            compressed.extractall(WORK, filter="data")
        args = [str(source / "configure"), f"--prefix={PREFIX}", "--disable-dependency-tracking"]
        if name == "libmtp":
            args += ["--disable-mtpz", "--disable-silent-rules"]
        for command in (args, ["make", "-j4"], ["make", "install"]):
            subprocess.run(command, cwd=source, env=environment, check=True)
    print(f"Release libraries ready: {PREFIX}")


if __name__ == "__main__":
    main()
