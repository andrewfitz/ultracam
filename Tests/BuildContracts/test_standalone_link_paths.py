"""An enabled local SDK must load for standalone test binaries too."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import test_generation_modes as generation_fixtures

ROOT = Path(__file__).resolve().parents[2]


class StandaloneLinkPathTests(unittest.TestCase):
    def test_concurrent_queries_keep_separate_results_in_shared_scratch(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / 'scripts'
            scripts.mkdir()
            (scripts / 'vendors.py').write_text('''
from pathlib import Path
import sys
import time

if sys.argv[1] != 'query':
    sys.exit()
kind = sys.argv[sys.argv.index('--kind') + 1]
if kind != 'swift-sources':
    if kind == 'embed-json':
        sys.stdout.write('[]\\0')
    sys.exit()
vendor = sys.argv[sys.argv.index('--vendor') + 1]
sys.stdout.write(vendor + '\\0')
sys.stdout.flush()
if vendor == 'first':
    Path('first-ready').touch()
    while not Path('second-ready').exists():
        time.sleep(.01)
else:
    Path('second-ready').touch()
''')
            command = '''set -euo pipefail
source "$1"
task_root="$PWD"; check_root="$PWD"
query() {
  vendor_configure app "$1"
  printf '%s\\n' "${vendor_swift_sources[@]}" > "$1-result"
}
query first &
first_pid=$!
until [[ -e first-ready ]]; do sleep 0.01; done
query second
wait "$first_pid"
'''
            subprocess.run(['/bin/bash', '-c', command, 'fixture', str(ROOT / 'scripts/vendor-build.sh')],
                           cwd=root, check=True, capture_output=True, timeout=10)
            self.assertEqual((root / 'first-result').read_text(), 'first\n')
            self.assertEqual((root / 'second-result').read_text(), 'second\n')
            self.assertEqual(list(root.glob('vendor-query.*')), [])

    def test_global_sdk_link_includes_declared_runtime_search_paths(self):
        fixture = generation_fixtures.GenerationModeTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        shutil.copy2(ROOT / 'scripts/vendor-build.sh', fixture.root / 'scripts/vendor-build.sh')
        fixture.write('enabled.json', json.dumps({'sony': True}))
        env = dict(fixture.environment, ULTRACAM_SDK_INVENTORY=str(fixture.root / 'enabled.json'))
        command = '''set -euo pipefail
task_root="$1"; check_root="$2"
source "$task_root/scripts/vendor-build.sh"
vendor_configure test "" "" app
printf '%s\\0' ${vendor_link_args[@]+"${vendor_link_args[@]}"}
'''
        output = subprocess.check_output(['/bin/bash', '-c', command, 'fixture', str(fixture.root),
                                           str(fixture.root / 'scratch')], env=env)
        flags = output.decode().rstrip('\0').split('\0')
        sdk_lib = str(fixture.root / 'Vendors/Sony/SDK/lib')
        self.assertIn(sdk_lib, flags)
        self.assertIn(['-Xlinker', '-rpath', '-Xlinker', sdk_lib],
                      [flags[index:index + 4] for index in range(len(flags) - 3)])


if __name__ == '__main__':
    unittest.main()
