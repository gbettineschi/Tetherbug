#!/usr/bin/env python3
"""Build personal packages locally or request their automatic GitHub release."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = "gbettineschi/Tetherbug"
CERT = "66e308329c2e4813943e4cc1c9672831fb8897e3d65ac5d1ef252a90ce7a9be6"


def run(*args, env=None, capture=False, cwd=ROOT):
    result = subprocess.run(args, cwd=cwd, env=env, check=True, text=True,
                            stdout=subprocess.PIPE if capture else None)
    return result.stdout.strip() if capture else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--existing-tag", action="store_true",
                        help="Publish the exact version tag that triggered Actions")
    parser.add_argument("--mac-only", action="store_true", help="Build an unpublished, keyless Mac candidate")
    parser.add_argument("--android-only", action="store_true", help="Build the retained-key APK for the release pipeline")
    parser.add_argument("--version", help="Mac trial version; requires --mac-only")
    args = parser.parse_args()
    if args.existing_tag:
        parser.error("Existing tags require the protected signing workflow; raw builds cannot be published.")
    if args.version and not args.mac_only or args.mac_only and args.publish or args.mac_only and args.android_only:
        parser.error("Mac trials cannot publish or change Android versions.")
    if run("git", "status", "--porcelain", capture=True):
        parser.error("Commit the release tree first; builds must match their source tag.")
    properties = dict(re.findall(r"^(versionName|versionCode)=(.+)$",
                                (ROOT / "android/gradle.properties").read_text(), re.M))
    version, code = properties["versionName"], properties["versionCode"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not code.isdigit():
        parser.error("Use a numeric x.y.z version and an increasing Android versionCode.")
    notes = ROOT / "releases" / f"{version}.md"
    if not notes.is_file():
        parser.error(f"Missing release notes: releases/{version}.md")
    tag = f"v{version}"
    sha = run("git", "rev-parse", "HEAD", capture=True)
    if args.mac_only:
        version = args.version or version
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?", version) or len(version) > 64:
            parser.error("Invalid Mac trial version.")
        run("bash", "macos/test.sh")
        out = ROOT / "build/releases" / version
        out.mkdir(parents=True, exist_ok=True)
        build_mac(out, version)
        print(f"Built unpublished Mac candidate: {out}")
        return
    if args.publish:
        try:
            verify_publication_source(tag, sha, args.existing_tag)
        except ValueError as error:
            parser.error(str(error))
        if not args.existing_tag:
            # A local request starts the one automatic publisher. It must not
            # also create a competing local release for the same version.
            run("git", "push", f"https://github.com/{REPO}.git", f"{sha}:refs/tags/{tag}")
            print(f"Tagged {tag}; GitHub Actions will build, sign and publish both apps.")
            return

    config_path = Path(os.environ.get("TETHER_SIGNING_CONFIG",
                      str(Path.home() / ".local/share/tetherbug/android-signing/signing.json")))
    signing = json.loads(config_path.read_text())
    keystore = Path(signing["keystore"]).expanduser()
    if not keystore.is_absolute():
        keystore = config_path.parent / keystore
    if not keystore.is_file():
        parser.error("The retained personal Android signing key is missing.")
    env = os.environ.copy()
    env.update(TETHER_KEYSTORE=str(keystore), TETHER_KEYSTORE_PASSWORD=signing["password"],
               TETHER_KEY_ALIAS=signing["alias"], TETHER_KEY_PASSWORD=signing["password"])
    sdk = Path(env.get("ANDROID_HOME") or env["ANDROID_SDK_ROOT"])
    tools = sorted((sdk / "build-tools").iterdir(),
                   key=lambda p: [int(n) for n in re.findall(r"\d+", p.name)])[-1]
    out = ROOT / "build/releases" / version
    out.mkdir(parents=True, exist_ok=True)

    if not args.android_only:
        run("bash", "macos/test.sh")
    run("./gradlew", "testDebugUnitTest", "--tests", "ie.xav.tetherbug.AutoStartTest",
        "--tests", "ie.xav.tetherbug.BluetoothTransportTest", "assembleRelease",
        "--no-daemon", "--console=plain", env=env, cwd=ROOT / "android")
    apk = out / f"tetherbug-v{version}.apk"
    shutil.copyfile(ROOT / "android/build/outputs/apk/release/tetherbug-release.apk", apk)
    certs = run(str(tools / "apksigner"), "verify", "--print-certs", str(apk),
                env=env, capture=True)
    digests = re.findall(r"certificate SHA-256 digest: ([0-9a-f]+)", certs)
    if digests != [CERT]:
        raise RuntimeError("APK signing certificate differs from the installed personal builds.")
    badging = run(str(tools / "aapt"), "dump", "badging", str(apk), capture=True)
    identity = re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'", badging)
    if not identity or identity.groups() != ("ie.xav.tetherbug", code, version):
        raise RuntimeError("APK identity or version does not match the release sources.")

    assets = [apk]
    if not args.android_only:
        assets.append(build_mac(out, version))
    checksums = out / "SHA256SUMS.txt"
    checksums.write_text("".join(f"{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n"
                                 for p in assets))
    manifest = out / "release.json"
    manifest.write_text(json.dumps({"version": version, "androidVersionCode": int(code),
                                   "sourceCommit": sha, "androidCertificateSha256": CERT,
                                   "macosSigning": "ad-hoc; not notarized"}, indent=2) + "\n")
    print(f"Built {version}: {out}; publication requires the protected Mac signer.")


def build_mac(out, version):
    archive = out / f"Tetherbug-v{version}.zip"
    with tempfile.TemporaryDirectory(prefix="tetherbug-package-") as staging:
        run("bash", "macos/build.sh", staging, version, "arm64", "x86_64")
        app = Path(staging) / "Tetherbug.app"
        run("codesign", "--verify", "--deep", "--strict", str(app))
        run("ditto", "-c", "-k", "--keepParent", str(app), str(archive))
    return archive


def verify_publication_source(tag, sha, existing_tag):
    if existing_tag:
        if os.environ.get("GITHUB_REF") != f"refs/tags/{tag}":
            raise ValueError("The Actions tag must match android/gradle.properties.")
        remote_sha = run("gh", "api", f"repos/{REPO}/commits/{tag}", "--jq", ".sha", capture=True)
        if remote_sha != sha:
            raise ValueError("The remote version tag differs from this source commit.")
        run("git", "merge-base", "--is-ancestor", sha, "origin/main")
        return
    remote_sha = run("gh", "api", f"repos/{REPO}/commits/main", "--jq", ".sha", capture=True)
    if remote_sha != sha:
        raise ValueError("Push this commit to the fork's main branch before publishing.")
    existing = run("git", "ls-remote", "--tags", f"https://github.com/{REPO}.git",
                   f"refs/tags/{tag}", capture=True)
    if existing:
        raise ValueError("This version already has a remote tag. Publish a new version instead.")


if __name__ == "__main__":
    main()
