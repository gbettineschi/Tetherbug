"""Allow only a version tag or an explicitly pinned unpublished Mac trial."""
import json
from pathlib import Path
import re


def from_environment(environment):
    sha = environment.get('GITHUB_SHA', '')
    ref = environment.get('GITHUB_REF', '')
    event = environment.get('GITHUB_EVENT_NAME', '')
    if environment.get('GITHUB_REPOSITORY') != 'gbettineschi/Tetherbug' or not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise ValueError('Wrong signing repository or source')
    if event == 'push' and re.fullmatch(r'refs/tags/v[0-9]+\.[0-9]+\.[0-9]+', ref):
        return {'sign_mac': True, 'source_sha': sha}
    if event == 'workflow_dispatch' and ref.startswith('refs/heads/'):
        inputs = json.loads(Path(environment['GITHUB_EVENT_PATH']).read_text()).get('inputs', {})
        if inputs.get('mode') == 'mac-trial' and inputs.get('expected_sha') == sha and re.fullmatch(r'v[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.]+)?', inputs.get('tag', '')):
            return {'sign_mac': True, 'source_sha': sha}
    raise ValueError('Signing needs an exact source review; PR signing is forbidden')
