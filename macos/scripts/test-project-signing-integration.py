#!/usr/bin/env python3
"""Opt-in real signature fixture: temporary keys only, no trust or privacy grants."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import secrets
import shutil
import subprocess
import tempfile
import zipfile


def run(args, *, env=None, check=True):
    result = subprocess.run(args, env=env, capture_output=True, text=True)
    if check and result.returncode:
        spec = importlib.util.spec_from_file_location('failure_classifier', Path(__file__).with_name('sign-candidate.py'))
        classifier = importlib.util.module_from_spec(spec); spec.loader.exec_module(classifier)
        reason = classifier.failure_reason(result.stdout + result.stderr)
        raise AssertionError(f'{Path(args[0]).name} failed (exit {result.returncode}; reason {reason})')
    return result


def requirement(app):
    result = run(['codesign', '--display', '-r-', str(app)])
    return next(line.removeprefix('designated => ') for line in (result.stdout + result.stderr).splitlines()
                if line.startswith('designated => '))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allow-temporary-keychain-probe', action='store_true')
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--candidate-zip', type=Path)
    args = parser.parse_args()
    if not args.allow_temporary_keychain_probe:
        parser.error('Explicit temporary-keychain probe consent is required')
    app = args.app.resolve()
    if app.name != 'Tetherbug.app' or '.build' not in app.parts:
        parser.error('Use only a hidden .build fixture, never an installed app')
    run(['codesign', '--verify', '--deep', '--strict', str(app)])
    before = run(['security', 'list-keychains', '-d', 'user']).stdout
    record = {}
    with tempfile.TemporaryDirectory(prefix='tetherbug-private-signature-fixture-') as temporary:
        root = Path(temporary)
        root.chmod(0o700)
        keychain = root / 'fixture.keychain-db'
        password = secrets.token_urlsafe(32)
        try:
            run(['security', 'create-keychain', '-p', password, str(keychain)])
            run(['security', 'unlock-keychain', '-p', password, str(keychain)])
            certs = []
            for number in (1, 2):
                directory = root / f'cert{number}'
                directory.mkdir(mode=0o700)
                config = directory / 'cert.cnf'
                config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n'
                                  '[dn]\nCN=Tetherbug Ephemeral Fixture\n[ext]\nbasicConstraints=critical,CA:FALSE\n'
                                  'keyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
                pem, key, p12 = (directory / name for name in ('cert.pem', 'key.pem', 'fixture.p12'))
                run(['openssl', 'req', '-new', '-newkey', 'rsa:2048', '-x509', '-sha256', '-nodes', '-days', '1',
                     '-config', str(config), '-keyout', str(key), '-out', str(pem)])
                key.chmod(0o600)
                environment = os.environ.copy()
                environment['TETHERBUG_FIXTURE_PASSWORD'] = password
                run(['openssl', 'pkcs12', '-export', '-inkey', str(key), '-in', str(pem), '-out', str(p12),
                     '-passout', 'env:TETHERBUG_FIXTURE_PASSWORD'], env=environment)
                run(['security', 'import', str(p12), '-k', str(keychain), '-P', password, '-T', '/usr/bin/codesign'])
                der = subprocess.run(['openssl', 'x509', '-in', str(pem), '-outform', 'DER'], check=True, capture_output=True).stdout
                certs.append((hashlib.sha1(der).hexdigest(), hashlib.sha256(der).hexdigest()))
            apps = []
            script = Path(__file__).with_name('sign-app.sh')
            for index in range(3):
                destination = root / str(index) / 'Tetherbug.app'
                shutil.copytree(app, destination)
                info = destination / 'Contents/Info.plist'
                data = plistlib.loads(info.read_bytes())
                data['CFBundleShortVersionString'] = f'0.0.{index+1}'
                data['CFBundleVersion'] = data['CFBundleShortVersionString']
                info.write_bytes(plistlib.dumps(data))
                environment = os.environ.copy()
                environment.update(TETHERBUG_SIGNING_PROFILE='project', TETHERBUG_REQUIRE_STABLE_SIGNING='1',
                                   TETHERBUG_CODESIGN_IDENTITY=certs[index // 2][0], TETHERBUG_CODESIGN_KEYCHAIN=str(keychain))
                run(['bash', str(script), str(destination)], env=environment)
                apps.append(destination)
            a, b, c = apps
            assert requirement(a) == requirement(b)
            assert (a / 'Contents/MacOS/Tetherbug').read_bytes() != (b / 'Contents/MacOS/Tetherbug').read_bytes()
            for candidate in (a, b):
                run(['codesign', '--verify', '--deep', '--strict', '--test-requirement', '=' + requirement(a), str(candidate)])
            assert run(['codesign', '--verify', '--strict', '--test-requirement', '=' + requirement(a), str(c)], check=False).returncode != 0
            # Exercise the exact signing-only archive API with the real fixture key.
            source = root / 'input.zip'
            if args.candidate_zip:
                shutil.copyfile(args.candidate_zip, source)
            else:
                with zipfile.ZipFile(source, 'w', zipfile.ZIP_DEFLATED) as archive:
                    for file in app.rglob('*'):
                        if file.is_file():
                            archive.write(file, 'Tetherbug.app/' + file.relative_to(app).as_posix())
            spec = importlib.util.spec_from_file_location('candidate', Path(__file__).with_name('sign-candidate.py'))
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            wrong = root / 'wrong/Tetherbug.app'
            shutil.copytree(b, wrong)
            run(['codesign', '--force', '--timestamp=none', '--keychain', str(keychain), '--sign', certs[0][0],
                 '--identifier', 'different.app', str(wrong)])
            run(['codesign', '--verify', '--deep', '--strict', str(wrong)])
            wrong_zip = root / 'wrong.zip'
            with zipfile.ZipFile(wrong_zip, 'w', zipfile.ZIP_DEFLATED) as archive:
                for file in wrong.rglob('*'):
                    if file.is_file(): archive.write(file, 'Tetherbug.app/' + file.relative_to(wrong).as_posix())
            try:
                module.sign_candidate(wrong_zip, root / 'wrong-signed.zip', certs[0][0], keychain, 'a' * 40)
            except ValueError: pass
            else: raise AssertionError('Valid signature with wrong incoming code identifier was accepted')
            assert not (root / 'wrong-signed.zip').exists()
            output = root / 'signed.zip'
            receipt = module.sign_candidate(source, output, certs[0][0], keychain, 'a' * 40)
            assert receipt['sha256'] == hashlib.sha256(output.read_bytes()).hexdigest()
            with zipfile.ZipFile(output) as archive:
                assert all(name.startswith('Tetherbug.app/') for name in archive.namelist())
                archive.extractall(root / 'checked')
            run(['codesign', '--verify', '--deep', '--strict', str(root / 'checked/Tetherbug.app')])
            # Exercise the CI import/cleanup wrapper with fixture secrets only.
            spec = importlib.util.spec_from_file_location('ci_signing', Path(__file__).with_name('ci-project-signing.py'))
            ci = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(ci)
            runner_temp = root / 'runner-temp'
            runner_temp.mkdir(mode=0o700)
            event = root / 'event.json'
            event.write_text(json.dumps({'inputs': {'tag': 'v0.0.3', 'mode': 'mac-trial', 'expected_sha': 'a' * 40}}))
            import base64
            environment = {'RUNNER_TEMP': str(runner_temp), 'GITHUB_REPOSITORY': 'gbettineschi/Tetherbug',
                           'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_REF': 'refs/heads/fixture',
                           'GITHUB_SHA': 'a' * 40, 'GITHUB_EVENT_PATH': str(event),
                           'MACOS_SIGNING_PKCS12_BASE64': base64.b64encode((root / 'cert1/fixture.p12').read_bytes()).decode(),
                           'MACOS_SIGNING_PKCS12_PASSWORD': password, 'MACOS_SIGNING_CERTIFICATE_SHA1': certs[0][0]}
            ci.sign(source, root / 'ci-signed.zip', 'a' * 40, environment)
            assert not (runner_temp / 'tetherbug-project-signing').exists()
            info = a / 'Contents/Info.plist'
            info.write_bytes(info.read_bytes() + b'\n')
            assert run(['codesign', '--verify', '--deep', '--strict', str(a)], check=False).returncode != 0
            record = dict(sameCertificateAcrossUpdates=True, changedSignedBytes=True, wrongCertificateRejected=True,
                          tamperingRejected=True, realArchiveSignerPassed=True, realCIWrapperPassed=True, wrongIncomingSigningIDRejected=True,
                          tccGranted=False, trustChanged=False)
        finally:
            if keychain.exists():
                run(['security', 'delete-keychain', str(keychain)])
            assert run(['security', 'list-keychains', '-d', 'user']).stdout == before, 'Temporary keychain search list not restored'
    record['temporaryMaterialRemoved'] = True
    print(json.dumps(record, indent=2))


if __name__ == '__main__':
    main()
