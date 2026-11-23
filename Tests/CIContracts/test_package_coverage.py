import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RUSTUP_SCRIPTS = ['build.sh', 'camera-smoke.sh', 'monitor-app-integration.sh', 'monitor-feed-host-checks.sh',
                  'program-stream-app-smoke.sh', 'test.sh', 'ui-verify.sh']


class PackageCoverageTests(unittest.TestCase):
    def test_ci_checkout_can_select_the_tracked_auto_switcher_without_a_sibling(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory).resolve() / 'ultracam'
            (checkout / 'scripts').mkdir(parents=True)
            (checkout / 'Apps').symlink_to(ROOT / 'Apps')
            script = checkout / 'scripts/auto_switcher_source.py'
            shutil.copyfile(ROOT / 'scripts/auto_switcher_source.py', script)
            selected = subprocess.check_output([sys.executable, str(script)], text=True)
            self.assertEqual(Path(selected.strip()), checkout / 'Apps/AutoSwitcher')

    def test_every_in_repo_package_with_tests_runs_in_test_sh(self):
        script = (ROOT / 'scripts/test.sh').read_text()
        packages = [p.parent.name for p in (ROOT / 'Packages').glob('*/Package.swift')
                    if (p.parent / 'Tests').is_dir() and p.parent.name != 'MonitorKit']
        self.assertTrue(packages)
        for name in packages:
            self.assertRegex(script, r'package_test\s+' + re.escape(name) + r'\b', f'{name} tests never run')

    def test_rustup_scripts_find_a_rustup_installed_outside_path(self):
        for name in RUSTUP_SCRIPTS:
            script = (ROOT / 'scripts' / name).read_text()
            fallback = script.find('.cargo/bin')
            self.assertNotEqual(fallback, -1, f'{name} has no ~/.cargo/bin fallback')
            self.assertLess(fallback, script.find('rustup which'), f'{name} needs the fallback before rustup')


if __name__ == '__main__':
    unittest.main()
