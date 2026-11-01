"""A static the offscreen verifier sets is a test hook: it must not ship in the app."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def ui_verify_lines(source):
    """Line numbers inside an `#if UI_VERIFY` branch, not its `#else`."""
    inside, stack = set(), []
    for number, line in enumerate(source.splitlines(), 1):
        directive = line.strip()
        if directive.startswith('#if'):
            stack.append(directive == '#if UI_VERIFY')
        elif directive.startswith('#else') or directive.startswith('#elseif'):
            if stack:
                stack[-1] = False
        elif directive.startswith('#endif'):
            if stack:
                stack.pop()
        elif any(stack):
            inside.add(number)
    return inside


class VerifyHooksCompiledOutTests(unittest.TestCase):
    def test_statics_the_verifier_sets_exist_only_in_ui_verify_builds(self):
        assigned = set()
        for tool in (ROOT / 'Tools/UIVerify').glob('*.swift'):
            assigned |= set(re.findall(r'\b([A-Z]\w*)\.([a-z]\w*)\s*=(?!=)', tool.read_text()))
        self.assertIn(('UIWindowVisibilityReader', 'treatsPresentedWindowsAsVisible'), assigned)
        for owner, member in sorted(assigned):
            declarations, uses = [], []
            for path in sorted((ROOT / 'Sources/App').glob('*.swift')):
                source = path.read_text()
                inside = ui_verify_lines(source)
                for number, line in enumerate(source.splitlines(), 1):
                    if re.search(r'\bstatic\s+var\s+' + member + r'\b', line):
                        declarations.append((path.name, number, number in inside))
                    elif re.search(r'\b' + member + r'\b', line) and not line.strip().startswith('///'):
                        uses.append((path.name, number, number in inside))
            self.assertTrue(declarations, f'{owner}.{member} has no declaration in Sources/App')
            for name, number, compiled_out in declarations + uses:
                self.assertTrue(compiled_out, f'{name}:{number}: {owner}.{member} is outside #if UI_VERIFY')


if __name__ == '__main__':
    unittest.main()
