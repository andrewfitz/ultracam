#!/usr/bin/env python3
from pathlib import Path
import re
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/SonyCameraControl.mm').read_text()
fields = re.findall(r'\{CrDeviceProperty_\w+, "([^"\n]+)", "([^"\n]+)", (?:true|false)\}', source)
resource = root / 'Resources/en.lproj/SonyControl.strings'
assert resource.is_file(), 'Sony localization resource is missing'
text = resource.read_text()
keys = re.findall(r'^"([^"]+)"\s*=', text, re.M)
assert len(keys) == len(set(keys)), 'Duplicate Sony localization keys'
for identifier, title in fields + [('cameraDisplay', 'HDMI display')]:
    assert f'"sony.control.{identifier}" = "{title}";' in text, identifier
assert '"sony.descriptor.name" = "Sony";' in text
for choice in ['on', 'off']:
    assert f'sony.control.choice.{choice}' in keys
print(f'Sony localization checks passed: {len(fields) + 1} property labels and static choices')
