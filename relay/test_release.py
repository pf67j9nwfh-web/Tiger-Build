"""Release regressions; isolated fixtures, no live settings or credentials."""
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import settings_gui

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('setup_release', ROOT / 'scripts/setup.py')
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)

class GuiTests(unittest.TestCase):
    def test_missing_controller_reports_error(self):
        with patch('settings_gui.subprocess.Popen', side_effect=OSError):
            self.assertIn('error', settings_gui.command('missing.py', 'status'))

    def test_timeout_kills_controller(self):
        with patch('settings_gui.subprocess.Popen') as spawn:
            proc = spawn.return_value
            proc.communicate.side_effect = [subprocess.TimeoutExpired('control', 90), (b'', b'')]
            self.assertIn('timed out', settings_gui.command('control.py', 'status')['error'])
            proc.kill.assert_called_once()
    def test_backup_overwrite_is_private_and_complete(self):
        with tempfile.TemporaryDirectory() as folder:
            dest = Path(folder) / 'backup.plist'
            dest.write_bytes(b'old')
            os.chmod(dest, 0o644)
            settings_gui.private_write(str(dest), b'new' * 10000)
            self.assertEqual(dest.read_bytes(), b'new' * 10000)
            if os.name != 'nt':
                self.assertEqual(dest.stat().st_mode & 0o777, 0o600)

class UpgradeTests(unittest.TestCase):
    def fixture(self, base):
        source, support = Path(base) / 'source', Path(base) / 'support'
        for folder in (source / 'relay', source / 'ppc-commander', source / 'scripts', support / 'app'):
            folder.mkdir(parents=True)
        (source / 'relay/new.py').write_text('new')
        (support / 'app/marker').write_text('old')
        (support / 'app/.env').write_bytes(b'fixture-placeholder\n')
        return source, support

    def test_env_preserved_without_source_env(self):
        with tempfile.TemporaryDirectory() as base:
            source, support = self.fixture(base)
            with patch.object(setup, 'ROOT', str(source)):
                setup.copy_app(str(support))
            self.assertEqual((support / 'app/.env').read_bytes(), b'fixture-placeholder\n')
            self.assertTrue((support / 'app/relay/new.py').exists())
    def test_copy_failure_leaves_old_tree(self):
        with tempfile.TemporaryDirectory() as base:
            source, support = self.fixture(base)
            with patch.object(setup, 'ROOT', str(source)), patch.object(setup.shutil, 'copytree', side_effect=OSError):
                with self.assertRaises(OSError):
                    setup.copy_app(str(support))
            self.assertEqual((support / 'app/marker').read_text(), 'old')
            self.assertEqual(list(support.iterdir()), [support / 'app'])

    def test_stop_failure_is_checked_and_secret_output_not_reprinted(self):
        reply = subprocess.CompletedProcess([], 1, b'opaque status output', b'opaque stderr')
        with patch.object(setup.subprocess, 'run', return_value=reply) as run:
            with self.assertRaisesRegex(RuntimeError, 'upgrade aborted'):
                setup.stop_installed('old-control.py')
            self.assertEqual(run.call_args.kwargs['stdout'], subprocess.PIPE)
            self.assertEqual(run.call_args.kwargs['stderr'], subprocess.PIPE)

    def test_swap_failure_restores_old_tree(self):
        with tempfile.TemporaryDirectory() as base:
            source, support = self.fixture(base)
            rename = os.rename
            def fail_new(src, dst):
                if Path(src).name.startswith('app-new-'):
                    raise OSError('fixture failure')
                return rename(src, dst)
            with patch.object(setup, 'ROOT', str(source)), patch.object(setup.os, 'rename', side_effect=fail_new):
                with self.assertRaises(OSError):
                    setup.copy_app(str(support))
            self.assertEqual((support / 'app/marker').read_text(), 'old')


class SshVersionTests(unittest.TestCase):
    def version_for(self, banner):
        reply = subprocess.CompletedProcess([], 0, b'', banner)
        with patch.object(setup.subprocess, 'run', return_value=reply):
            return setup.ssh_version()

    def test_parses_unix_and_windows_banners(self):
        self.assertEqual(self.version_for(b'OpenSSH_10.3p1, LibreSSL 3.3.6'), (10, 3))
        self.assertEqual(self.version_for(b'OpenSSH_for_Windows_9.5p2, LibreSSL 3.8.2'), (9, 5))
        self.assertEqual(self.version_for(b'OpenSSH_8.1p1'), (8, 1))

    def test_missing_ssh_is_unknown(self):
        with patch.object(setup.subprocess, 'run', side_effect=OSError):
            self.assertIsNone(setup.ssh_version())
