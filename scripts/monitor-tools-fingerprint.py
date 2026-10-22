#!/usr/bin/env python3
"""Capture/verify exact qualification inputs without touching app state."""
import argparse
import datetime
import hashlib
import json
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('action',choices=['capture','verify'])
parser.add_argument('manifest',type=Path)
args=parser.parse_args()
repo=Path(__file__).resolve().parents[1]
paths=set((repo/'Packages/MonitorTools/Sources').rglob('*.swift'))
paths.update((repo/'Packages/MonitorTools/Sources').rglob('*.metal'))
paths.update((repo/'Packages/MonitorTools/Sources').rglob('*.metal.txt'))
paths.update((repo/'Sources/Recording').glob('*.swift'))
paths.update((repo/'Tools/MonitorToolsRecording').glob('*.swift'))
paths.update((repo/'Tools/MonitorToolsRecordingTests').glob('*.swift'))
paths.update(repo/p for p in ['Packages/MonitorTools/Package.swift','Tools/MonitorToolsRecording/main.swift','Tools/MonitorToolsSmoke/main.swift','Sources/Shared/CubeLUT.swift','Sources/App/LUTProcessor.swift','Sources/App/AppResourceUsage.swift','Sources/App/LUTShaders.metal','Sources/Shared/VideoContract.swift','Sources/Shared/VideoBufferLayout.swift','scripts/monitor-tools-package.sh','scripts/monitor-tools-recording.sh','scripts/monitor-tools-smoke.sh','scripts/monitor-tools-stress.sh','scripts/monitor-tools-fingerprint.py','scripts/monitor-tools-admission-checks.sh'])
files={p.relative_to(repo).as_posix():hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(paths)}
if args.action=='capture':
    args.manifest.write_text(json.dumps({'algorithm':'SHA-256','captured_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'files':files},sort_keys=True,indent=2)+'\n')
else:
    expected=json.loads(args.manifest.read_text())['files']
    changed=sorted(p for p in set(expected)|set(files) if expected.get(p)!=files.get(p))
    if changed: raise SystemExit('Qualification source changed: '+', '.join(changed))
