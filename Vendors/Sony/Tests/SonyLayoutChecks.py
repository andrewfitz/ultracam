#!/usr/bin/env python3
"""Final Sony source/resource ownership; independent of optional SDK install."""
from pathlib import Path

root = Path(__file__).resolve().parents[3]
vendor = root / 'Vendors/Sony'
required = [
    'SDK/README.md',
    'Resources/SonyAssets.xcassets/Contents.json',
    'Resources/SonyAssets.xcassets/SonyLogo.imageset/Contents.json',
    'Resources/SonyAssets.xcassets/SonyLogo.imageset/sony.svg',
    'Tests/Credentials.swift', 'Tests/Hardware.mm', 'Tests/Native.mm',
    'Tests/NativeModels.swift', 'Tests/SandboxUI.swift', 'Tests/Snapshot.swift',
    'Tests/main.swift', 'Tests/PARITY.md', 'Tests/SonyPluginChecks.swift',
]
missing = [str(vendor / path) for path in required if not (vendor / path).is_file()]
old = [path for path in [root / 'ThirdParty/SonyCameraRemoteSDK',
    root / 'Tools/SonyControlChecks', root / 'Config/Assets.xcassets/SonyLogo.imageset'] if path.exists()]
assert not missing and not old, f'Sony ownership incomplete: missing={missing}; old={old}'
assert '#include "../Sources/SonyCameraControl.mm"' in (vendor / 'Tests/Native.mm').read_text()
assert '#import "../Sources/SonyCameraControl.h"' in (vendor / 'Tests/Hardware.mm').read_text()
print('Sony layout checks passed')
