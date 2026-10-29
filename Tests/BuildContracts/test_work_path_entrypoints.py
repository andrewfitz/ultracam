import unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
class BuildEntryPointPathTests(unittest.TestCase):
    def test_no_build_script_requires_a_particular_drive(self):
        for path in sorted((ROOT/'scripts').iterdir()):
            if path.suffix in ('.sh','.py'):
                with self.subTest(script=path.name):
                    self.assertFalse('/Volumes/8TB' in path.read_text(), path.name+' still requires a particular drive')
if __name__=='__main__':unittest.main()
