import importlib.util
from pathlib import Path
import tempfile
import unittest
spec=importlib.util.spec_from_file_location('ownership',Path(__file__).resolve().parents[1]/'integrations/prontarr_ownership.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class OwnershipTests(unittest.TestCase):
 def test_exclusive_durable_and_authenticated_release(self):
  with tempfile.TemporaryDirectory() as folder:
   path=Path(folder)/'ownership.json';gate=m.Ownership(path);body={'app':'radarr','media_id':48,'job_id':1}
   result=gate.update(body,{})
   self.assertEqual(result,gate.update(body,{}));self.assertEqual(path.stat().st_mode&0o777,0o600)
   restarted=m.Ownership(path);self.assertTrue(restarted.owns('radarr',48))
   with self.assertRaises(m.Conflict):restarted.update(body|{'job_id':2},{})
   with self.assertRaises(m.Conflict):restarted.update(body|{'token':'wrong'},{},True)
   restarted.update(body|result,{},True);self.assertFalse(m.Ownership(path).owns('radarr',48))
 def test_legacy_scope_cannot_be_claimed(self):
  with tempfile.TemporaryDirectory() as folder:
   gate=m.Ownership(Path(folder)/'ownership.json')
   with self.assertRaises(m.Conflict):gate.update({'app':'sonarr','media_id':9,'job_id':1},{'old':{'app':'sonarr','mid':'9'}})
if __name__=='__main__':unittest.main(verbosity=2)
