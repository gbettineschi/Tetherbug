#!/usr/bin/env python3
"""Publish only packages from this run's keyless builder and protected Mac signer."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = 'gbettineschi/Tetherbug'
ANDROID_CERT = '66e308329c2e4813943e4cc1c9672831fb8897e3d65ac5d1ef252a90ce7a9be6'


def regular(path):
    if path.is_symlink() or not path.is_file(): raise ValueError('Missing or linked release file')
    return path


def validate(raw, signed, version, code, source, certificate):
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[0-9a-f]{40}', source) or not re.fullmatch(r'[0-9a-f]{40}', certificate):
        raise ValueError('Invalid release identity')
    manifest = json.loads(regular(raw/'release.json').read_text())
    receipt = json.loads(regular(signed/'signing.json').read_text())
    expected = {'version': version, 'androidVersionCode': code, 'sourceCommit': source, 'androidCertificateSha256': ANDROID_CERT}
    if any(manifest.get(k) != v for k, v in expected.items()): raise ValueError('Builder identity mismatch')
    requirement = f'identifier "ie.xav.tetherbug" and certificate leaf = H"{certificate}"'
    expected_receipt = {'version': version, 'build': version, 'sourceCommit': source, 'certificateSha1': certificate, 'designatedRequirement': requirement}
    if any(receipt.get(k) != v for k, v in expected_receipt.items()): raise ValueError('Protected signing identity mismatch')
    mac = regular(signed/f'Tetherbug-v{version}.zip')
    apk = regular(raw/f'tetherbug-v{version}.apk')
    if hashlib.sha256(mac.read_bytes()).hexdigest() != receipt.get('sha256'): raise ValueError('Signed Mac archive changed')
    checks = dict((line.split('  ', 1)[1], line.split('  ', 1)[0]) for line in regular(raw/'SHA256SUMS.txt').read_text().splitlines())
    if checks.get(apk.name) != hashlib.sha256(apk.read_bytes()).hexdigest(): raise ValueError('Verified APK changed')
    return expected | {'macosSigning': {'type': 'project certificate; not notarized', 'certificateSha1': certificate, 'designatedRequirement': requirement}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('raw', type=Path); parser.add_argument('signed', type=Path)
    args = parser.parse_args()
    properties = dict(re.findall(r'^(versionName|versionCode)=(.+)$', (ROOT/'android/gradle.properties').read_text(), re.M))
    version, code = properties['versionName'], int(properties['versionCode'])
    source = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
    import importlib.util
    spec = importlib.util.spec_from_file_location('release_source', ROOT/'scripts/release.py')
    release = importlib.util.module_from_spec(spec); spec.loader.exec_module(release)
    release.verify_publication_source('v'+version, source, True)
    public = ROOT/'docs/signing/tetherbug-project.pem'
    der = subprocess.check_output(['openssl', 'x509', '-in', str(public), '-outform', 'DER'])
    certificate = hashlib.sha1(der).hexdigest()
    manifest = validate(args.raw, args.signed, version, code, source, certificate)
    with tempfile.TemporaryDirectory(prefix='tetherbug-publish-') as directory:
        root = Path(directory)
        files = []
        for original in [args.raw/f'tetherbug-v{version}.apk', args.signed/f'Tetherbug-v{version}.zip', args.signed/'signing.json']:
            target = root/original.name; shutil.copyfile(original, target); files.append(target)
        (root/'release.json').write_text(json.dumps(manifest, indent=2)+'\n')
        (root/'SHA256SUMS.txt').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))
        subprocess.run(['gh', 'release', 'create', 'v'+version, '--repo', REPO, '--verify-tag', '--title',
            f"Tetherbug (gbettineschi's version) {version}", '--notes-file', str(ROOT/f'releases/{version}.md'),
            '--latest', *(str(p) for p in [*files, root/'release.json', root/'SHA256SUMS.txt'])], check=True)


if __name__ == '__main__': main()
