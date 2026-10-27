#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
check_root=/Volumes/8TB/cinesomatic-build/sony-credential-checks
mkdir -p "$check_root"
sources=("$task_root/Sources/App/SonyCameraCredentials.swift" "$task_root/Tools/SonyControlChecks/Credentials.swift")
xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  "${sources[@]}" -framework Security -o "$check_root/credential-checks"
"$check_root/credential-checks"

# Real platform qualification is explicit and uses only a random test service.
# Usage: sony-credential-checks.sh --keychain /path/to/provisioned.app 'signing identity'
if [[ "${1:-}" != --keychain ]]; then exit 0; fi
if [[ $# != 3 ]]; then echo 'Expected --keychain <provisioned app> <matching signing identity>.' >&2; exit 2; fi
reference_app="$2"
signing_identity="$3"
test_service="org.ultracam.sony-credential-checks.$(/usr/bin/uuidgen)"
helper_a="$check_root/reinstall-A/SonyCredentialChecks.app"
helper_b="$check_root/reinstall-B/SonyCredentialChecks.app"
/usr/bin/codesign -d --entitlements - --xml "$reference_app" > "$check_root/reference-entitlements.plist"
python3 - "$check_root" "$reference_app" <<'PY'
import os, pathlib, plistlib, shutil, sys
root, reference = map(pathlib.Path, sys.argv[1:])
ent = plistlib.loads((root / 'reference-entitlements.plist').read_bytes())
app_id = ent['com.apple.application-identifier']
team = ent['com.apple.developer.team-identifier']
bundle = plistlib.loads((reference / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
assert app_id.endswith('.' + bundle), 'Reference signing identity is inconsistent.'
profile = reference / 'Contents/embedded.provisionprofile'
assert profile.is_file(), 'A provisioning profile is required for data-protection Keychain qualification.'
# Reproduce the complete production security context, including app groups.
# Opt-in diagnostic override tests a private group using the actual app ID.
if os.environ.get('SONY_CREDENTIAL_PRIVATE_GROUP') == '1':
    ent['keychain-access-groups'] = [app_id]
(root / 'helper-entitlements.plist').write_bytes(plistlib.dumps(ent))
for variant in ('reinstall-A', 'reinstall-B'):
    app = root / variant / 'SonyCredentialChecks.app'
    (app / 'Contents/MacOS').mkdir(parents=True, exist_ok=True)
    (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle, 'CFBundleName': 'Sony Credential Checks',
        'CFBundleExecutable': 'SonyCredentialChecks', 'CFBundlePackageType': 'APPL',
        'CFBundleShortVersionString': '1.0' if variant == 'reinstall-A' else '2.0',
    }))
    shutil.copyfile(profile, app / 'Contents/embedded.provisionprofile')
PY
xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  "${sources[@]}" -framework Security -o "$helper_a/Contents/MacOS/SonyCredentialChecks"
xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -D SONY_CREDENTIAL_UPDATE_CHECK "${sources[@]}" -framework Security -o "$helper_b/Contents/MacOS/SonyCredentialChecks"
for helper in "$helper_a" "$helper_b"; do
  /usr/bin/codesign --force --sign "$signing_identity" --timestamp=none --options runtime \
    --entitlements "$check_root/helper-entitlements.plist" "$helper"
  /usr/bin/codesign --verify --strict "$helper"
done
cleanup() { "$helper_a/Contents/MacOS/SonyCredentialChecks" --process-cleanup "$test_service" >/dev/null 2>&1 || true; }
trap cleanup EXIT
"$helper_a/Contents/MacOS/SonyCredentialChecks" --keychain
"$helper_a/Contents/MacOS/SonyCredentialChecks" --process-save "$test_service"
"$helper_b/Contents/MacOS/SonyCredentialChecks" --process-read-update "$test_service"
"$helper_a/Contents/MacOS/SonyCredentialChecks" --process-verify-delete "$test_service"
echo 'Sony signed Keychain persistence checks passed across processes, changed executable content and app paths.'
