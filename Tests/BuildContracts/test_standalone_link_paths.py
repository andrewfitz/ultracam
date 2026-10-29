"""An enabled local SDK must load for standalone test binaries too."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import unittest

import test_generation_modes as generation_fixtures

ROOT = Path(__file__).resolve().parents[2]


class StandaloneLinkPathTests(unittest.TestCase):
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
