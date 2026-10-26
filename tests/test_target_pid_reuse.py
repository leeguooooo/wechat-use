"""Read-only process identity fixtures; no real service or target is controlled."""
from pathlib import Path
import types
import unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'install.sh').read_text().split("<<'PYINSTALL'\n",1)[1].split('\nPYINSTALL',1)[0]
installer=types.ModuleType('target_pid_fixture')
exec(compile(source,'<installer-fixture>','exec'),installer.__dict__)
class TargetPidReuseTests(unittest.TestCase):
    def test_target_pid_reuse_needs_two_stable_canonical_os_epochs(self):
        old='Sat Oct 17 20:03:41 2026';new='Thu Oct 22 10:58:52 2026'
        boot=1792627200000000000 # 2026-10-22 UTC; fixed test kernel boundary
        def row(value,code=0):return types.SimpleNamespace(returncode=code,stderr='',stdout=value+'\n')
        for expected,observations,accept in [
            (old,[row(new),row(new)],True),
            (old,[row(old),row(old)],False),
            (old,[row(new),row(old)],False),
            (old,[row('invalid')],False),
            ('untrusted epoch',[],False),
            ('Sun Oct 17 20:03:41 2026',[],False),
        ]:
            with patch.object(installer,'retirement_pid_absent',return_value=False),patch.object(installer.subprocess,'run',side_effect=observations):
                self.assertEqual(installer.retirement_target_exited(721,expected,boot),accept)
        with patch.object(installer.os,'kill',side_effect=PermissionError(1,'Operation not permitted')),patch.object(installer.subprocess,'run',side_effect=[row(new),row(new)]):
            self.assertTrue(installer.retirement_target_exited(721,old,boot))
        with patch.object(installer,'retirement_pid_absent',return_value=False),patch.object(installer.subprocess,'run',return_value=row('',1)):
            self.assertFalse(installer.retirement_target_exited(721,old,boot))
        with patch.object(installer,'retirement_pid_absent',return_value=False),patch.object(installer.subprocess,'run') as probe:
            self.assertFalse(installer.retirement_target_exited(721,new,boot))
            probe.assert_not_called()
        with patch.object(installer.os,'kill',side_effect=OSError(5,'unavailable')):
            with self.assertRaises(installer.Refused):installer.retirement_target_exited(721,old,boot)

if __name__=='__main__':unittest.main()
