# Monitor color reference receipt

Research date: 2026-10-19; Sony ARRI-style reference added 2026-10-20. Implementation: `ColorAnalysis.swift`. These are scalar
mathematical/reference qualifications, not an FX3 HDMI/capture-chain calibration
or a physical-camera qualification. Swift 5 mode, macOS 15, Foundation only.

## Versioned primary evidence

- [Sony S-Gamut3/S-Log3 technical summary](https://pro.sony/s3/cms-static-content/uploadfile/06/1237494271406.pdf),
  appendix p5: native S-Log3 forward/inverse formulas, breakpoint 0.01125,
  codes 95/420/598 for black/18%/90%. The inverse toe's printed `out +` is a
  typographic error; the inverse of the published forward affine branch is used.
  Browser successfully read the PDF; direct download returned HTTP 403, so no
  invented checksum is recorded. 90% code598 is rounded, not an exact inverse anchor.
- [ARRI LogC False Color specification](https://www.arri.com/resource/blob/390448/871b733469a2f2c2099ca51b1516bcd1/arri-logc-false-color-specification-data.pdf),
  version 2025-02-04, SHA256
  `463dadba55e5ceac748cb828db64b20fa5b604632bf69153727b532953be725a`.
  Equations1–2 and Table1 specify achromatic Log RGB weighting, gray fallback,
  boundary ownership and categorical colors. Tables9 and25 supply implemented
  10-bit legal/full EI800 bounds. The legal and full tables are independently
  rounded; converting the rounded legal integers does not reproduce full values.
- [ARRI ALEXA Log C Curve — Usage in VFX (2017)](https://www.arri.com/resource/blob/31918/66f56e6abb6e5b6553929edf9aa7483e/2017-03-alexa-logc-curve-in-vfx-data.pdf),
  p4 formula and p9 exposure-value table: EI800 uses cut 0.010591,
  a 5.555556, b 0.052272, c 0.247190, d 0.385537, e 5.367655,
  f 0.092809. These exposure-value parameters are used for the Sony reference
  adaptation; the p8 sensor-signal parameters are a different domain.
- [OpenColorIO Sony builtins](https://raw.githubusercontent.com/AcademySoftwareFoundation/OpenColorIO/main/src/OpenColorIO/transforms/builtins/SonyCameras.cpp),
  primary implementation source from Academy Software Foundation. Retrieved
  SHA256 `8be9c5db71767216dd294eb7eedd34055329032bd1325e65dc67be047cccec74`.
  Standard S-Gamut3 primaries are (0.730,0.280),(0.140,0.855),(0.100,-0.050);
  S-Gamut3.Cine (0.766,0.275),(0.225,0.800),(0.089,-0.087), both D65
  (0.3127,0.3290). Implemented linear Y coefficients are the Y row of the RGB-to-XYZ
  matrix derived by scaling those primary XYZ columns to D65. Venice-specific
  matrices in that source are distinct and are not silently selected here.

Transport YCbCr matrix coefficients and scene-linear gamut Y coefficients are
separate types. Never compute scene exposure by applying inverse Log to encoded
luma: inverse each RGB channel, then combine using its source gamut. Wide-gamut
negative coefficients and negative channel values are retained; nonpositive Y has
no finite stop value. No arbitrary LUT output is interpreted as scene exposure.

Native Log normalization is separate from code-container legal/full interpretation.
`NativeLogCodeMapping` needs independently established transported native endpoints.
For native Sony codes, 420/1023 is gray; (420-64)/876 is not. The technical summary's
range statements concern its documented cameras, and do not prove the current
FX3 HDMI, capture device, driver or v210 transport mapping. That chain remains
unqualified pending measured references. No inferred metadata makes it qualified.

## ARRI scope and exact semantics

Literal ARRI profiles remain `arri-logc3-ei800` and `arri-alexa35-logc4-ei800`,
with `ARRI-2025-02-04` specification identity. Each selects exact 10-bit table
bounds and requires matching LogC input at EI800; this does not claim higher-bit
analytic-threshold precision. No guessed EI interpolation or ALEXA265 profile exists.
Sony S-Log3 has the separately labeled reference adaptation described below.

Table classifier input is achromatic code; RGB convenience input is normalized
LogC RGB. ARRI deliberately specifies Rec.709-like achromatic weights
0.21260/0.71520/0.07220 even for its wide-gamut encoding. All intervals include
the lower bound and exclude the upper. Thus nominal maximum code940 legal or
1023 full falls back to achromatic gray, as equation2 requires. Foot/headroom
outside categories also stays gray. Invalid values return unavailable. Categorical
pink is (1,0.7,0.7), purple (0.7,0,1), others exact primary/secondary RGB values.
These are output display categories; do not apply another camera/viewing LUT.

## ARRI-style false color on Sony S-Log3

`SonyARRIStyleFalseColor` implements **ARRI-style — S-Log3** for source profiles
`sony-slog3-sgamut3cine` and `sony-slog3-sgamut3`. It requires no ARRI camera.
Its stable profile ID is `arri-style-slog3-logc3-ei800-v1`, with specification
identity `ARRI-style-SLog3-LogC3-EI800-v1`. This is a luminance-based reference
adaptation, distinct from the literal ARRI LogC RGB classifier above.

Each native normalized S-Log3 RGB channel is inverse-decoded using Sony's formula.
The selected Sony gamut's scene-linear Y coefficients combine those channels.
That Y is encoded using the published **exposure-value** LogC3 EI800 formula,
then multiplied by 1023 and classified by the existing independently rounded
LogC3 **full-range** table. The reference table therefore does not change with
transport code range; native Sony normalization is established before this step.
Applying an inverse curve to encoded luma would give different results on colored
subjects and is not this algorithm.

Unclassified pixels use original native S-Log3 achromatic RGB with weights
0.2126/0.7152/0.0722. They do not use LogC3 gray. Negative source-gamut Y is retained
through the reference formula's linear toe, without clipping. Unsupported source
gamuts and nonfinite intermediate results return unavailable. Categorical colors
are the published ARRI display RGB values and bypass a subsequent viewing LUT.

EI800 is fixed for the **reference transform**, independent of the Sony camera's
exposure index. Highlights and shadows are reference exposure bands; they do not
identify the Sony sensor's clipping limit, noise floor or usable dynamic range.
Physical FX3/capture-chain qualification remains separate from this scalar and
shader reference adaptation.

## EL Zone research and remaining qualification

> **Removed 2026-10-24.** EL Zone false colour is no longer part of MonitorKit (0.1.0) or
> Ultracam. A saved EL Zone selection reads as false colour off with every other setting
> kept (`LegacyMonitorConfiguration.normalized()`, `MonitorState` decoding). The EL Zone
> sections below are kept as the research record only.

Actively examined these public primary sources:

- [Creator's official homepage](https://www.elzonesystem.com/) and
  [media/extended-range explanation](https://www.elzonesystem.com/media), plus
  [articles page](https://www.elzonesystem.com/articles) and linked images.
  They establish identity and show the extended palette; the media page explicitly
  discusses sensor latitude and extending stops. They provide no numerical
  RGB triplets, complete threshold intervals or boundary inclusion rules.
- [Panasonic EL Zone setup guide for VariCam LT/35 firmware9](https://pna-b2b-storage-mkt.s3.amazonaws.com/production/292763_EL_Zone_System_Setup_Guide_for_VariCam_LT_and_35.pdf),
  SHA256 `d607e4189356c7dc09f77c93ae4d1be04a44c740b34829045a1b7f06d288a6f8`.
  Pages1–4 describe fifteen labels, integer stops with additional +/-half-stop
  labels, gray at18%, black/white extrema and visual colored swatches. A further vector-content inspection located numerical DeviceRGB rectangle
  operands on page2 (zero-based), documented below; it still does not provide
  exact interval endpoints.
  Its conventional false-color IRE percentages are a different diagram and
  must not be mistaken for EL Zone thresholds.
- [SmallHD Exposure Assist reference](https://guide.smallhd.com/a/808517),
  [Ultra10 guide](https://guide.smallhd.com/a/1902476-ultra-10-monitor-quick-start-guide),
  and [PageOS6](https://smallhd.com/pages/os): require the matching Log/color pipe
  upstream of viewing LUT and describe updated wider dynamic-range support.
  No numerical palette/boundary specification was located on these pages.
- [Sony VENICE2 official product reference](https://pro.sony/en_MK/pdf/products/digital-cinema-cameras/venice2)
  describes stops relative to18% and use of original sensor data for clipping.
  The plan's CineAlta Workflow Guide PDF could not be retrieved by this browser
  request; that failure is not treated as evidence that a specification is absent.

These findings establish stop-domain math, a versioned public vector-chart
palette, and source requirements, but not exact continuous EL Zone compatibility.
Midpoint thresholds are an implementation convention, rather than information
established by those sources; extended palettes and sensor clipping behavior vary.
`ELZoneReferenceStatus` therefore reports vendor parity as unqualified. The
available `ELZoneProfile` below explicitly versions Ultracam's public-chart mapping.
`halfStopBand` is explicitly generic fixture quantization and must not be exposed
as EL Zone. No approximate palette, permission assumption, outreach or licensing
claim was made. To close qualification establish that the versioned chart palette matches the
intended implementation, plus interval ownership, luminance/achromatic algorithm and clipping/offset
rules for each supported input profile, then validate against independent reference
images or vectors. Public-source research alone has not established integration terms.

## Verification

`ColorAnalysisTests` checks independent Sony anchors, both sides of the Log branch,
range rescaling at8/10/12/16 bits, preserved headroom, saturated source gamut Y,
scene stop calculations, zebra interval edges, scope rasterization, invalid input,
and every published ARRI lower/upper boundary across both profiles and ranges.
Sony adaptation regressions add independently evaluated LogC3 reference anchors,
neutral category vectors, a saturated red vector that distinguishes both Sony
gamuts and rejects encoded-luma shortcuts, native-S-Log3 gray fallback, negative
luminance, unsupported profiles/gamuts, and nonfinite channels. Configuration
round trips preserve Sony ARRI-style mode independently of the camera EI. The
isolated full Core suite passed 44 tests on 2026-10-20 using
`/Volumes/8TB/cinesomatic-build/monitor-sony-arri-core-20261020`.
No physical cameras were opened. Package-wide execution initially encountered the
concurrently implemented Metal target; isolated core-only package verification
uses `/Volumes/8TB/cinesomatic-build/monitor-color-isolated-build`.

## Focused patent and vector-asset follow-up

Located and downloaded [Cinecam/Edward Lachman US11223776B1](https://patents.google.com/patent/US11223776B1/en)
and its [original patent PDF](https://patentimages.storage.googleapis.com/90/94/2b/1ac2df87315810/US11223776.pdf).
The browser fetch failed, but direct HTTP retrieval succeeded. PDF SHA256:
`0cc8edfafbe5bb105184d66f5aacab19bf1d80c66e835added90d98d090a07b6`.
Description accompanying Figure4 and claims5/6 explicitly establish fifteen labels
and inclusive white >=+6 / black <=-6. The text specifies color families for the
intermediate stops but no numerical RGB or internal transition boundaries.
The PDF drawings are raster images; they were not sampled for palette values.
No patent-scope, legal status, permission or license conclusion is drawn.

The authoritative Panasonic firmware9 guide **does contain vector reference
colors**. Inspected original page3 content object35 with
`qpdf --show-object=35 --filtered-stream-data elzone-panasonic.pdf`.
The rectangle fills use DeviceRGB (`rg`); their x coordinates map to the printed
stop labels in the same object. Values, copied without screenshot sampling:

| Stop | PDF RGB operands |
| --- | --- |
| -6 | 0,0,0 |
| -5 | .439,.188,.627 |
| -4 | 0,.439,.753 |
| -3 | 0,.69,.941 |
| -2 | .0824,.651,.0549 |
| -1 | .192,.878,.141 |
| -.5 | 0,1,0 |
| 0 | .533,.537,.506 |
| +.5 | .973,.949,0 |
| +1 | 1,.992,.463 |
| +2 | 1,.565,0 |
| +3 | 1,.694,.357 |
| +4 | 1,0,0 |
| +5 | 1,.412,.412 |
| +6 | 1,1,1 |

These qualify a **public chart reference palette**, not proof of the operational
firmware's output transform or an extended-range palette. In particular the
published middle-gray swatch is slightly tinted; it has deliberately not been
changed to an invented neutral RGB. `ELZonePublicReference` versions this evidence,
provides known stop-to-linear-luminance anchors and resolves only exact labels plus
the explicit extrema. Interior values without a published interval return nil.
This evidence alone cannot classify arbitrary frames with exact vendor parity.
The operational `ELZoneProfile` adds the explicitly documented continuous-band
convention below. A seven-test core suite covers the original chart evidence.

Also searched official Sigma fp functions, Atomos Ninja/ELZone product references,
Sony VENICE2 operating instructions, and official/vendor downloadable LUT/SDK
queries. No authoritative continuous numerical thresholds or downloadable official
classifier LUT was located in this bounded pass. Sony's conventional false-color
IRE threshold table is explicitly a separate mode and is not reused for EL Zone.

## Sony S-Log3 false color (current Sony preset)

`SonySLog3FalseColor`, profile `sony-slog3-false-color-v1`, specification identity
`sony-monitor-control-pattern2-v1`, implements the **Pattern2 (S-Log3)** values in
[Sony Monitor & Control, Shooting Assist Functions](https://helpguide.sony.net/promobile/mc/v1/en/contents/shooting_assist_functions.html)
(retrieved 2026-10-20). This replaces the selectable Sony ARRI-style adaptation;
saved configurations with its historical profile ID migrate to this Sony preset.
The old mathematical reference remains solely for compatibility with existing
reference tests and decoding. Literal ARRI profiles are not Sony presets.

| Category | Lower IRE | Upper IRE | App display RGB |
| --- | ---: | ---: | --- |
| Red | 93.4 | 96.1 | 1, 0, 0 |
| Orange | 87.7 | 90.6 | 1, .5, 0 |
| Yellow | 91.3 | 93.4 | 1, 1, 0 |
| Cyan | 43.8 | 46.5 | 0, 1, 1 |
| Pink | 54.3 | 58 | 1, .4, .7 |
| Light pink | 47.8 | 50.8 | 1, .7, .8 |
| Green | 38.9 | 42.2 | 0, 1, 0 |
| Light blue | 24.6 | 34.4 | .3, .65, 1 |
| Blue | 3.5 | 5.6 | 0, 0, 1 |
| Purple | -7 | 3.5 | .6, 0, 1 |

Sony publishes named color families and numerical lower/upper limits on that page,
not numerical display RGB or shared-edge ownership. The RGB triplets above are
explicit **Ultracam display choices**, not a claim of exact Sony UI colors.
Ultracam uses lower-inclusive, upper-exclusive intervals. No interpolation fills
Sony's gaps, and no category extends beyond its published bounds. Uncategorized
pixels retain native S-Log3 signal luma as achromatic gray, preserving numerical
footroom and headroom until display rasterization. Category RGB bypasses the
viewing LUT.

Classification uses source encoded signal luma, not decoded scene luminance:
`IRE = (nativeNormalized * 1023 - 64) / 876 * 100`. For RGB input the selected
transport matrix computes encoded signal luma from already reconstructed native
S-Log3 RGB. Native code420 is approximately40.6393 IRE (green); code95 is
approximately3.5388 IRE (blue). Thus encoded black is not assigned a guessed
sensor-noise category, and the upper red interval is not an asserted camera
clipping point. Camera EI and exposure offsets do not move these IRE intervals.

The legal/full transport attachment does not determine native S-Log3 scaling.
Explicit `NativeLogCodeMapping` reconstructs native normalized code first; only
then is the Sony IRE formula applied. This preserves equivalent classifications
for native10-bit and full-to-legal-rescaled transport. The supported source
identities are `sony-slog3-sgamut3cine` and `sony-slog3-sgamut3`; an unspecified or
incompatible source disables this preset. Physical camera/capture qualification
remains separate from these scalar and shader reference checks.

## Operational EL Zone public-chart profile

> **Removed 2026-10-24** with EL Zone itself (see above); `ELZoneProfile`,
> `ELZonePublicReference` and `ELZoneReferenceStatus` no longer exist.

`ELZoneProfile` now provides the selectable operational **EL Zone · Public chart**
profile, ID `ultracam-elzone-public-chart-v1`, specification identity
`Ultracam-PanasonicFW9-Midpoints-v1`. This supersedes the earlier wording that all
EL Zone operation remains disabled. Exact Sony Monitor & Control compatibility
remains unqualified: `ELZoneReferenceStatus.isQualified` concerns that vendor
compatibility claim and does not gate this explicitly declared public-chart profile.
No Sony M&C app test was performed.

The fifteen numerical display RGB values and labels are the existing
`ELZonePublicReference` Panasonic firmware9 vector-chart palette, unchanged.
Ultracam explicitly supplies the otherwise unpublished continuous-classifier
convention. Black owns all finite stops <=-6 and white owns all finite stops >=+6.
The first interior (-5 label) is (-6,-4.5). The remaining interiors are
lower-inclusive and upper-exclusive with transitions at -4.5, -3.5, -2.5, -1.5,
-.75, -.25, +.25, +.75, +1.5, +2.5, +3.5, and +4.5 stops. Gray is [-.25,+.25).
Equalities select the higher exposure category, except -6 belongs to black.
These midpoint interiors are an **Ultracam implementation convention**, not a
published Sony or Panasonic firmware transition specification. The +/-6 extrema
retain the established public reference instead of using guessed +/-5.5 cutoffs.

Reconstruct native normalized S-Log3 RGB from its explicitly declared transport
mapping, decode each channel separately with Sony's inverse curve, and combine
scene-linear RGB with the declared S-Gamut3 or S-Gamut3.Cine Y coefficients.
Positive finite Y is classified using
`log2(Y) - log2(0.18) + referenceOffsetStops`. The user offset is additive in stops;
there is no automatic camera EI or Display LUT gain. Finite nonpositive Y remains
black even with a positive offset. Unsupported source gamuts, nonfinite inputs,
and nonfinite intermediate results return unavailable. The selected profile and
version are persisted for supported Sony sources; legacy unversioned/public-chart
EL selections migrate while preserving camera EI and the user offset.

Nine new Core tests cover every transition on both sides and at equality, all
fifteen chart anchors, native neutral anchors, offset direction, saturated colors
that distinguish Sony gamuts, negative Y, nonfinite/overflow rejection, strict
source/profile configuration and migration. A meaningful configuration RED run
failed two tests with nine expected assertions before implementation; the full
isolated Core suite then passed 63 tests with no failures. Receipts are under
`/Volumes/8TB/cinesomatic-build/ultracam-monitor-upgrade-20261021/core` in
`red-el-config.log` and `green-el-core.log`. This validates the stated convention;
it does not claim comparison against Sony M&C's implementation.
