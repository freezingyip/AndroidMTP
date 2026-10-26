#!/usr/bin/env python3
"""Package the local development app with its dynamically linked MTP libraries."""
import os
import plistlib
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "build" / "AndroidMTP.app"


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def dependencies(path):
    lines = run("/usr/bin/otool", "-L", str(path)).splitlines()[1:]
    return [line.strip().split(" (", 1)[0] for line in lines]


def minimum_os(path):
    output = run("/usr/bin/xcrun", "vtool", "-show-build", str(path))
    versions = re.findall(r"\bminos\s+([\d.]+)", output)
    return max((tuple(map(int, value.split("."))) for value in versions), default=(13, 0))


def main():
    binary = Path(sys.argv[1]).resolve()
    if not binary.is_file():
        raise SystemExit("Build the executable before packaging.")
    # This is a generated, project-local build artifact.
    if APP.exists():
        shutil.rmtree(APP)
    macos = APP / "Contents" / "MacOS"
    frameworks = APP / "Contents" / "Frameworks"
    resources = APP / "Contents" / "Resources"
    for directory in [macos, frameworks, resources]:
        directory.mkdir(parents=True)
    executable = macos / "AndroidMTP"
    shutil.copy2(binary, executable)

    originals = {}
    pending = [binary]
    while pending:
        source = pending.pop()
        for dependency in dependencies(source):
            if not dependency.startswith(("/opt/homebrew/", "/usr/local/")):
                continue
            path = Path(dependency).resolve()
            if path in originals:
                continue
            name = path.name
            if name in originals.values():
                raise SystemExit(f"Dependency name collision: {name}")
            originals[path] = name
            shutil.copy2(path, frameworks / name)
            os.chmod(frameworks / name, 0o755)
            pending.append(path)

    for source, destination in [(binary, executable)] + [
        (source, frameworks / name) for source, name in originals.items()
    ]:
        if destination != executable:
            subprocess.run(["/usr/bin/install_name_tool", "-id", f"@rpath/{destination.name}", str(destination)], check=True)
        for dependency in dependencies(source):
            if not dependency.startswith(("/opt/homebrew/", "/usr/local/")):
                continue
            name = originals[Path(dependency).resolve()]
            prefix = "@executable_path/../Frameworks/" if destination == executable else "@loader_path/"
            subprocess.run(["/usr/bin/install_name_tool", "-change", dependency, prefix + name, str(destination)], check=True)

    notices = resources / "ThirdPartyLicenses"
    notices.mkdir()
    shutil.copy2(ROOT / "THIRD_PARTY_NOTICES.md", notices)
    for source in originals:
        copying = source.parent.parent / "COPYING"
        if copying.exists():
            shutil.copy2(copying, notices / f"{source.stem}-COPYING.txt")
    minimum = max([minimum_os(binary)] + [minimum_os(source) for source in originals])
    with (APP / "Contents" / "Info.plist").open("wb") as handle:
        plistlib.dump({
            "CFBundleName": "AndroidMTP",
            "CFBundleDisplayName": "AndroidMTP",
            "CFBundleIdentifier": "local.androidmtp.app",
            "CFBundleExecutable": "AndroidMTP",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.3.1",
            "CFBundleVersion": "4",
            "LSMinimumSystemVersion": ".".join(map(str, minimum)),
            "NSHighResolutionCapable": True,
            "NSSupportsAutomaticGraphicsSwitching": True,
            "NSHumanReadableCopyright": "AndroidMTP — local development build",
        }, handle)
    for library in frameworks.iterdir():
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(library)], check=True)
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(APP)], check=True)
    print(f"Built {APP}")


if __name__ == "__main__":
    main()
