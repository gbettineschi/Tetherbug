import importlib.util
from pathlib import Path
import os
import io
import tempfile
from contextlib import redirect_stdout
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("release", Path(__file__).parents[1] / "release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class PublicationSourceTests(unittest.TestCase):
    def test_local_request_delegates_without_needing_a_signing_key(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            (root / 'android').mkdir()
            (root / 'releases').mkdir()
            (root / 'android/gradle.properties').write_text('versionName=1.2.3\nversionCode=123\n')
            (root / 'releases/1.2.3.md').write_text('Release notes')
            calls = []
            def run(*args, **kwargs):
                calls.append(args)
                if args[:3] == ('git', 'status', '--porcelain'): return ''
                if args[:3] == ('git', 'rev-parse', 'HEAD'): return 'abc'
                if args[:2] == ('gh', 'api'): return 'abc'
                if args[:2] == ('git', 'ls-remote'): return ''
                if args[:2] == ('git', 'push'): return None
                raise AssertionError(f'Local publish unexpectedly tried to build: {args}')
            with patch.object(release, 'ROOT', root), patch.object(release, 'run', side_effect=run), patch('sys.argv', ['release.py', '--publish']), redirect_stdout(io.StringIO()):
                release.main()
            self.assertIn(('git', 'push', 'https://github.com/gbettineschi/Tetherbug.git', 'abc:refs/tags/v1.2.3'), calls)

    def test_tag_job_requires_exact_event_tag_and_remote_commit(self):
        with patch.dict(os.environ, {"GITHUB_REF": "refs/heads/main"}), patch.object(release, "run") as run:
            with self.assertRaises(ValueError):
                release.verify_publication_source("v1.2.3", "abc", True)
            run.assert_not_called()
        with patch.dict(os.environ, {"GITHUB_REF": "refs/tags/v1.2.3"}), patch.object(release, "run", return_value="other"):
            with self.assertRaises(ValueError):
                release.verify_publication_source("v1.2.3", "abc", True)
        with patch.dict(os.environ, {"GITHUB_REF": "refs/tags/v1.2.3"}), patch.object(release, "run", return_value="abc"):
            release.verify_publication_source("v1.2.3", "abc", True)

    def test_local_publish_still_requires_main_and_an_unused_tag(self):
        with patch.object(release, "run", return_value="other"):
            with self.assertRaises(ValueError):
                release.verify_publication_source("v1.2.3", "abc", False)
        with patch.object(release, "run", side_effect=["abc", "existing tag"]):
            with self.assertRaises(ValueError):
                release.verify_publication_source("v1.2.3", "abc", False)
        with patch.object(release, "run", side_effect=["abc", ""]):
            release.verify_publication_source("v1.2.3", "abc", False)
