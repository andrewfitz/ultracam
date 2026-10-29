# SDK release evidence

Status as of 2026-10-27: **official public release blocked pending Sony
redistribution evidence and completed artifact-specific license packaging**.
The bundle validator checks artifact-specific evidence and packaging. Its checks
do not grant vendor rights or determine whether the recorded terms legally
permit distribution. No official release is approved by this document.

| Component | Available evidence | Still required for an official release |
|---|---|---|
| Ultracam | Root Apache-2.0 LICENSE and NOTICE; vendor-plan decision 4 | Include applicable license and notice files in the distributed artifact |
| MonitorKit | Package LICENSE and NOTICE | Preserve package notices in the release |
| DeckLink SDK interfaces | Original per-file license blocks; SDK README identifies 16.0 | Preserve blocks on relocation/distribution; review applicable SDK EULA for the acquisition and release |
| Desktop Video driver | SDK README identifies an externally installed driver | Do not treat interface-header terms as a grant for the driver installer |
| Sony SDK and CrAdapter dependencies | Local headers/dylibs and installation README only | Exact SDK version, archive name/hash and provenance; accepted EULA/license text and version/date; terms or written permission supporting downloadable-app runtime redistribution; complete runtime inventory and upstream license/notice files, including adapter dependencies |
| Rust auto-switcher | Cargo.lock and locally cached crate license metadata, listed in THIRD_PARTY_LICENSES.md | Derive actual target/feature dependency set and collect required license/notice texts, including native components |

Record Sony evidence with a durable reference to the applicable terms (or an
access-controlled record if it cannot be published), the precise clauses that
permit the proposed distribution, any conditions, the SDK/archive identity,
the release artifact hash, and the person/date of the completed review. Do not
put credentials or confidential contracts into the public repository.

The build plan requires Sony in official releases. Missing SDKs may remain
supported in local unsigned/debug workflows, but missing permission evidence
must never be interpreted as permission to publish an official release.

The SDKs were relocated from `ThirdParty/DeckLinkSDK/` and
`ThirdParty/SonyCameraRemoteSDK/` to `Vendors/Blackmagic/SDK/` and
`Vendors/Sony/SDK/`. Keep original vendor terms and provenance with the SDKs.

## Bundle validation contract

```sh
python3 scripts/validate_bundle.py /path/to/Ultracam.app --inventory /path/to/sdk-inventory.json
python3 scripts/validate_bundle.py /path/to/Ultracam.app --inventory /path/to/sdk-inventory.json --signed
```

Every mode inspects enabled vendor runtime presence, architecture, install names,
dependency resolution, declared host capabilities and extension exclusion.
`--arch arm64` selects a required architecture; repeat `--arch` for multiple
architectures. Without it, the host executable determines the required set.
`--signed` additionally verifies nested code and bundle signatures. This mode
alone does not declare an official release or approve redistribution.

Official validation additionally uses `--official-release --signed
--release-evidence /path/to/sony-release-evidence.json` with a Sony-enabled
inventory. It requires non-ad-hoc signatures, the root LICENSE, NOTICE and
THIRD_PARTY_LICENSES.md packaged in the app, and the evidence below. This is a
command contract, not a successful official-release receipt. Notarization is
a separate distribution step.

`build.sh --sdk-inventory /path/to/sdk-inventory.json` shares that inventory
with generation and validation. All signed builds invoke signed validation.
Official build policy is explicit: `--official-release` requires `--signed`
with Release configuration and rejects `--local-development`. An ordinary
signed Release build remains a local build unless that flag is provided.
`--release-evidence /path/to/sony-release-evidence.json` or
`ULTRACAM_RELEASE_EVIDENCE` supplies the evidence; missing proof causes official
validation to fail. These flags are implemented but do not imply a completed
official build. To review an existing final artifact, invoke the standalone
validator with its matching inventory and evidence; rebuilding is unnecessary.

| Evidence JSON field | Required value |
|---|---|
| `schemaVersion` | Integer `1` |
| `vendorID` | `sony` |
| `sdkVersion` | Exact Sony version from the manifest |
| `reviewedBy` | Nonempty reviewer identity |
| `reviewedAt` | ISO date, `YYYY-MM-DD` |
| `termsReference` | Nonempty durable reference to the applicable terms |
| `redistributionClauses` | Nonempty record of the clauses supporting this distribution |
| `archiveName`, `provenance` | Nonempty archive identity and acquisition record |
| `archiveSHA256` | 64 lowercase hexadecimal characters identifying the reviewed archive |
| `artifactSHA256` | Exact validator digest of the final app bundle |
| `runtimeInventory` | Exact set of Sony manifest runtime destinations relative to `Contents/Frameworks`, such as `libCr_Core.dylib` and `CrAdapter/libssh2.dylib` |
| `packagedNotices` | Nonempty list of existing license/notice files, with paths relative to the app bundle |

The artifact digest is `validate_bundle.bundle_digest(app)`, not the hash of a
ZIP, DMG or the executable alone. It hashes sorted relative file paths encoded
as UTF-8 followed by a NUL byte, then each file's raw SHA-256 digest, into one
SHA-256 stream. Compute it after final packaging/signing; changing a file changes
the evidence binding. Keep the evidence JSON outside the app to avoid making
its own artifact hash circular.

The code checks field structure, declared runtime inventory, packaged notice
paths and artifact binding. Human review must still establish the accuracy of
archive provenance and the recorded permission, including all dependency terms
and conditions. Do not create placeholder evidence to bypass the open gate.
