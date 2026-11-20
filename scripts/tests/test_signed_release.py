import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('publish_signed', Path(__file__).parents[1]/'publish-signed.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class SignedReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.raw = self.root/'raw'; self.raw.mkdir()
        self.signed = self.root/'signed'; self.signed.mkdir()
        self.sha = 'a'*40; self.cert = 'b'*40
        self.apk = self.raw/'tetherbug-v1.2.3.apk'; self.apk.write_bytes(b'fixture apk')
        self.mac = self.signed/'Tetherbug-v1.2.3.zip'; self.mac.write_bytes(b'fixture signed zip')
        self.manifest = {'version':'1.2.3','androidVersionCode':123,'sourceCommit':self.sha,'androidCertificateSha256':module.ANDROID_CERT}
        self.receipt = {'version':'1.2.3','build':'1.2.3','sourceCommit':self.sha,'certificateSha1':self.cert,
            'designatedRequirement':'identifier "ie.xav.tetherbug" and certificate leaf = H"'+self.cert+'"',
            'sha256':hashlib.sha256(self.mac.read_bytes()).hexdigest()}
        self.write()
    def write(self):
        (self.raw/'release.json').write_text(json.dumps(self.manifest))
        (self.signed/'signing.json').write_text(json.dumps(self.receipt))
        (self.raw/'SHA256SUMS.txt').write_text(hashlib.sha256(self.apk.read_bytes()).hexdigest()+'  '+self.apk.name+'\n')
    def check(self):return module.validate(self.raw,self.signed,'1.2.3',123,self.sha,self.cert)
    def test_verified_packages_are_accepted(self):
        value = self.check(); self.assertEqual(value['macosSigning']['certificateSha1'],self.cert)
    def test_old_ad_hoc_or_wrong_source_is_refused(self):
        for field,value in [('certificateSha1','c'*40),('sourceCommit','c'*40),('version','1.2.2'),('build','4'),('designatedRequirement','cdhash fixture')]:
            with self.subTest(field=field):
                old=self.receipt[field]; self.receipt[field]=value; self.write()
                with self.assertRaises(ValueError):self.check()
                self.receipt[field]=old
    def test_modified_mac_or_android_bytes_are_refused(self):
        self.mac.write_bytes(b'changed')
        with self.assertRaises(ValueError):self.check()
        self.mac.write_bytes(b'fixture signed zip'); self.apk.write_bytes(b'changed')
        with self.assertRaises(ValueError):self.check()
    def test_changed_android_identity_is_refused(self):
        self.manifest['androidCertificateSha256']='c'*64; self.write()
        with self.assertRaises(ValueError):self.check()
    def test_symlinked_release_files_are_refused(self):
        elsewhere=self.root/'original';self.mac.rename(elsewhere);self.mac.symlink_to(elsewhere)
        with self.assertRaises(ValueError):self.check()

if __name__=='__main__':unittest.main()
