"""Read-only process identity fixtures; no real service or target is controlled."""
from pathlib import Path
import types
import unittest
import tempfile
import time
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/'install.sh').read_text().split("<<'PYINSTALL'\n",1)[1].split('\nPYINSTALL',1)[0]
installer=types.ModuleType('target_pid_fixture')
exec(compile(source,'<installer-fixture>','exec'),installer.__dict__)
class TargetPidReuseTests(unittest.TestCase):
    def namespace_fixture(self):
        cache=Path.home()/'.cache';cache.mkdir(exist_ok=True)
        temporary=tempfile.TemporaryDirectory(dir=cache);self.addCleanup(temporary.cleanup)
        entry=Path(temporary.name).resolve()/'entry';entry.mkdir(mode=0o700)
        worker=entry/'worker';worker.mkdir(mode=0o700)
        control=worker/'owner-control.json';control.write_text('{}');control.chmod(0o600)
        guard=installer.StoppedTargetRetirement.__new__(installer.StoppedTargetRetirement)
        with patch.object(installer,'retirement_boot_ns',return_value=1):
            installer.PrebootRetirement.__init__(guard,[],[])
        self.addCleanup(guard.close)
        guard.cutoff=time.time_ns()+600*10**9
        stat=worker.stat()
        binding=dict(namespace_device=stat.st_dev,namespace_inode=stat.st_ino+1)
        return guard,entry,worker,control,binding
    def test_reused_device_only_accepts_preboot_import_and_retains_current_fences(self):
        guard,entry,worker,control,binding=self.namespace_fixture()
        before=control.read_bytes()
        self.assertTrue(guard.retained_namespace_matches(binding,worker))
        self.assertEqual(control.read_bytes(),before)
        with patch.object(installer,'retirement_boot_ns',return_value=1),patch.object(installer,'retirement_sdk_quiet',return_value=None):
            installer.PrebootRetirement.check(guard)
            control.write_text('{} ')
            with self.assertRaises(installer.Refused):installer.PrebootRetirement.check(guard)
        guard.cutoff=time.time_ns()-600*10**9
        self.assertFalse(guard.retained_namespace_matches(binding,worker))
    def test_import_cannot_hide_directory_members_or_aliases(self):
        guard,entry,worker,control,binding=self.namespace_fixture()
        original=installer.os.walk
        def incomplete(*args,**kwargs):
            for directory,dirs,files in original(*args,**kwargs):
                yield directory,dirs,[n for n in files if n!='owner-control.json']
        with patch.object(installer.os,'walk',side_effect=incomplete):
            with self.assertRaises(installer.Refused):guard.retained_namespace_matches(binding,worker)
        alias=worker/'alias';alias.symlink_to(control)
        with self.assertRaises(installer.Refused):guard.retained_namespace_matches(binding,worker)
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
