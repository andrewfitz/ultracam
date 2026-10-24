# MonitorKit features

Every monitoring tool MonitorKit ships, with its parameters, defaults and ranges, what it does, and the device feature it follows. The reference devices are the Sony ILME-FX3 (help guide for Ver.2 and later, which covers firmware 7.00) and the Blackmagic Video Assist 12G HDR (manual of November 2025, software 3.22). Where a device does not publish a number, MonitorKit's value is marked **convention**. The math and its sources are in [MATH.md](MATH.md).

Product names identify the feature a mode follows. A user interface should name modes by behaviour ("Band zebra", "Six-band false colour"), not by device.

Contents:

1. [How tools are configured](#1-how-tools-are-configured)
2. [Exposure](#2-exposure): zebras, false colour, clip indicators
3. [Scopes](#3-scopes): waveform, vectorscope, histogram, statistics
4. [Focus](#4-focus): peaking, magnify, monochrome
5. [Framing](#5-framing): frame guides, safe areas, grids, de-squeeze, flip
6. [Colour pipeline](#6-colour-pipeline): LUTs, picture stage, display transforms, display adjustments, output colour and HDR
7. [Status and output](#7-status-and-output): clean feed, status overlay, Freeze, multiview
8. [Audio](#8-audio): level meters and loudness
9. [Why a tool is not drawn](#9-why-a-tool-is-not-drawn)
10. [Out of scope](#10-out-of-scope)

## 1. How tools are configured

All picture tools of one surface live in one value, `MonitorState` (MonitorKitCore). Changing it costs nothing on the GPU beyond new uniforms; only a new tool set or colour path selects another (already built or asynchronously built) pipeline. `MonitorState.normalized()` clamps every value to the ranges below and resets non-finite ones; every pass normalizes the state it is given.

Scopes are configured per scope with `ScopeSettings` (MonitorKitScopes), audio meters with `AudioMeterConfiguration` (MonitorKitAudio), and the target's colour with `MonitorOutputColor` (MonitorKitCore).

**Signal stages.** Every tool that measures the signal chooses one `SignalStage`, and all three come from one decode per pixel:

| Stage | What it is |
| --- | --- |
| `.source` | The camera signal as captured: range-expanded, matrix-decoded, never clipped |
| `.output` | After the feed's burn-in LUT: what the real output carries |
| `.monitor` | After the monitor-only LUT as well: what this surface shows |

Tools always measure their stage, never the display-transformed or output-encoded picture, so a display LUT or an HDR-to-SDR view never moves a zebra or a false-colour band.

**The signal is declared by the host.** `SignalDescription` (range, Y'CbCr matrix, chroma siting, transfer or log encoding, primaries) comes from the frame's CoreVideo attachments (`MonitorFrame.signal(of:range:)`) or from the host. Log encodings cannot be read from attachments, so a host declares them (`SignalEncoding.log(LogEncoding(…))`), as both devices ask the operator to.

## 2. Exposure

### 2.1 Zebras (`MonitorState.zebras`, two `ZebraSet`s)

Follows: FX3 Zebra (presets 70–100 and 100+ IRE; Custom1 is "level ± range", Custom2 "level and above") and Video Assist Zebra (one threshold, everything above it). MonitorKit has the FX3's two simultaneous sets, each in either mode.

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `enabled` | `false` | | Per set |
| `mode` | `.lowerLimit` | `.lowerLimit`, `.band` | Lower limit: IRE ≥ `level`. Band: `level − range` ≤ IRE < `level + range` (lower edge inclusive, upper exclusive) |
| `level` | 95 | −20…120 IRE | 0 is black, 100 nominal white (code 940 in a 10-bit legal container); above 100 reaches super-white |
| `range` | 5 | 0…30 IRE | **Half**-width of a band (the FX3's "± range"). A full-width setting of 10 is `range` 5 |
| `opacity` | 0.65 | 0…1 | Stripe mix |
| `stage` | `.output` | any stage | The signal measured |

- IRE is the stage luma in percent: the transport Y' where no LUT touched the stage, the Rec.709 Y' of a LUT result. The same value drives false colour, clip indicators and scope clip counts, so a 940 code is exactly 100 IRE everywhere.
- Set 1 draws light stripes rising to the right (`/`), set 2 dark stripes falling to the right (`\`), so overlapping sets stay readable. The stripe period is 16 points (8 on, 8 off), scaled by `MonitorViewport.pixelsPerPoint`.
- FX3 presets map to `.lowerLimit` at 70, 75, 80, 85, 90, 95 or 100 (100+ is the lower limit just above 100, e.g. 100.5). The secondary-source examples "44 ± 1" (grey) and "108+" / "94+" (Rec.709 and S-Log3 clip) are a band at 44 with `range` 1 and lower limits at 108 and 94.
- Overlay colours are authored as Rec.709 SDR at graphics white and encoded for the target, so on an HDR layer they sit at 203 cd/m² (58 % PQ, 75 % HLG) instead of peak white.

### 2.2 False colour (`MonitorState.falseColor`, `FalseColorSettings`)

Follows: the Video Assist's fixed false colour (`.sixBand`), Sony's Monitor & Control false colour for S-Log3 (`.sonySLog3`; not on the FX3 body), ARRI's LogC false colour (`.arriLogC`) and the published EL Zone chart (`.elZone`).

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `mode` | `.off` | see below | |
| `referenceOffsetStops` | 0 | −6…6 | Added to measured exposure, in stops (EL Zone and custom stops) |
| `stage` | `.output` | any stage | For `.sixBand` and `.custom`. Log modes always classify the source |
| `customUnit` | `.ire` | `.ire`, `.stops` | |
| `customBands` | `[]` | at most 16 (`maximumCustomBands`) | `FalseColorBand(lower:upper:color:)`, lower edge inclusive, upper exclusive; ±∞ for open ends; the first match wins |

Modes:

| Mode | Classifies | Bands | Status |
| --- | --- | --- | --- |
| `.sonySLog3` | Native S-Log3 signal luma in IRE (code − 64)/876·100 | Sony Pattern 2: purple −7.0–3.5, blue 3.5–5.6, light blue 24.6–34.4, green 38.9–42.2, cyan 43.8–46.5, light pink 47.8–50.8, pink 54.3–58, orange 87.7–90.6, yellow 91.3–93.4, red 93.4–96.1; grey elsewhere | verified against Sony's table; band ownership at shared edges is a convention |
| `.arriLogC` | The ARRI code of a LogC3 or LogC4 source (A' = Rec.709 weights on log R'G'B') | ARRI's published EI 800 tables, legal or full by the container and transport (`FalseColorTable.usesFullRangeARRI(signal:layout:)`) | verified (LogC4 regenerated from the specification) |
| `.arriStyleSLog3` | S-Log3 decoded to scene light, weighted by the source gamut, re-encoded with LogC3 EI 800 | ARRI LogC3 full-range table | MonitorKit adaptation |
| `.elZone` | Stops from 18 % grey of the decoded log source (+ `referenceOffsetStops`) | The public Panasonic FW9 EL Zone chart, 15 zones, midpoint transitions | **provisional** (no qualified reference; the status entry is marked `isProvisional`) |
| `.sixBand` | Display IRE of the stage | purple < 2.5, blue 2.5–8, green 38.4–43.4 (18 % grey = 40.9), pink 56.4–62.4 (+1 stop = 59.5), yellow 93–99, red ≥ 99; grey elsewhere | **convention**: Blackmagic labels the chart but publishes no edges |
| `.custom` | Stage IRE, or stops: scene light of an untouched log source, the display transfer's own light of a display source (BT.709, sRGB, PQ, HLG, linear), Rec.709 for a LUT stage | Your bands | verified per transfer |

- Log modes need a log source (`.requiresLogSource`) of the encoding they classify (`.unsupportedLogEncoding`: Sony Pattern 2 needs S-Log3, ARRI-style and EL Zone need S-Log3 on S-Gamut3 or S-Gamut3.Cine, the ARRI tables LogC3 or LogC4), and the camera's own signal (`.requiresCameraSignal` on a processed frame). Custom stops need a known transfer (`.requiresKnownTransfer`).
- `FalseColorLegend` (MonitorKitUI) builds the matching legend: names, ranges, swatches, captions, footnotes, the provisional note; `FalseColorLegendView` draws it as a `.list` or `.captioned` (monitor chrome) legend.
- `MonitorTileTool.suggestedFalseColorMode(for:)` picks Sony Pattern 2 for S-Log3, the ARRI table for LogC, and six-band otherwise.

### 2.3 Clip indicators (`MonitorState.clipIndicators`, `ClipIndicatorSettings`)

Not on either device (the nearest are zebras at 100+): a per-channel overlay of what is clipped, over or under.

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `enabled` | `false` | | |
| `stage` | `.output` | any stage | |
| `red`, `green`, `blue`, `luma` | all `true` | | Which values are tested (R', G', B' and Y' of the stage, in percent) |
| `showsOver`, `high` | `true`, 100 | −20…120 % | Over: value ≥ `high` |
| `showsUnder`, `low` | `true`, 0 | −20…120 % | Under: value ≤ `low` |
| `coloring` | `.perChannel` | `.perChannel`, `.uniform` | Per channel: red, green and blue added (two clipped channels show their mix, three white), under at half level, luma alone white (grey under). Uniform: `overColor` (red) / `underColor` (blue) |
| `opacity` | 1 | 0…1 | |

Clip percentages are scope statistics (`ScopeStatistics.clippedHigh` / `clippedLow`), computed with the same Float comparison, so with equal levels and stage they count exactly the pixels this overlay marks (`ClipReadout` in MonitorKitUI shows them).

## 3. Scopes

Follows: the Video Assist's scopes (luma waveform, RGB parade, vectorscope with 100 % targets and 1×/2×/4× zoom, RGB histogram, scope brightness, background opacity) and the FX3's luminance histogram. MonitorKit also has RGB overlay and Y'CbCr parade waveforms, 75 % targets, Rec.2020 targets, HDR graticules, and any number of scopes at once (the Video Assist shows one). Every pixel of the frame is counted, at the host's scope rate; the picture never waits for a scope.

### 3.1 `ScopeSettings`

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `kind` | `.waveform` | `.waveform`, `.vectorscope`, `.histogram` | |
| `stage` | `.output` | any stage | |
| `waveformMode` | `.luma` | `.luma`, `.rgbOverlay`, `.rgbParade`, `.ycbcrParade` | Y'CbCr parade chroma is offset so neutral sits at 50 % |
| `histogramMode` | `.rgbOverlay` | `.luma`, `.rgbOverlay`, `.rgbParade` | |
| `vectorscopeZoom` | 1 | 1, 2, 4 | Accumulated at the zoomed scale, so zoom adds real resolution |
| `colorimetry` | `.auto` | `.auto`, `.bt601`, `.bt709`, `.bt2020`, `.smpte240m` | Weights of the drawn luma, the Y'CbCr parade and the vectorscope. Auto: the frame's matrix for the source, Rec.709 after a LUT |
| `waveformColumns` | 1024 | 64…4096, even | Bins across the scope (split three ways in a parade) |
| `waveformLevels` | 512 | 64…2048 | Bins over `levelRange` |
| `histogramBins` | 512 | 64…4096, even | Bins over `levelRange` |
| `levelRange` | `.standard` | `.standard` (−7…109 %, every legal 10-bit code), `.minus10To110` | Waveform and histogram only |
| `vectorscopeSize` | 512 | 64…2048, even | Bins per side |
| `clipHighPercent`, `clipLowPercent` | 100, 0 | −20…120 | Statistics clip levels (as `ClipIndicatorSettings`) |
| `display` | `ScopeDisplay()` | | How it is drawn; changing it never re-accumulates |

`ScopeSettings.ultracamLegacy(mode:stage:)` is the look of Ultracam's earlier scopes: 768 × 256 bins over −10…110 IRE, the legacy palette and an opaque background; draw it into a 768 × 256 viewport (`ultracamLegacyImageWidth`, `ultracamLegacyImageHeight`).

### 3.2 `ScopeDisplay`

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `brightness` | 1 | 0…4 | Trace multiplier (the Video Assist's Scope Brightness) |
| `gain` | 1 | 0.05…20 | Bin density multiplier before the intensity curve |
| `intensity` | `.logarithmic` | `.logarithmic` (log(1 + 16x)/log 257), `.gamma` ((x/16)^(1/2.2)) | |
| `trace` | `.phosphor` | `.phosphor`, `.white`, `.colorized` | Colorized: each vectorscope point in the hue it measures |
| `palette` | `.standard` | `.standard`, `.ultracamLegacy` | Waveform and histogram colours |
| `backgroundOpacity` | 0.85 | 0…1 | Below 1 the scope overlays the picture (the Video Assist's Background Opacity) |
| `showsGraticule`, `graticuleOpacity` | `true`, 0.55 | 0…1 | |
| `waveformScale` | `.percent` | `.percent`, `.codeValues`, `.pqNits`, `.hlgNits` | Labels only: the bins are the same for every scale |
| `histogramScale` | `.linear` | `.linear`, `.logarithmic` | |
| `vectorscopeTargets` | `.both` | `.none`, `.percent75`, `.percent100`, `.both` | BT.2111 / RP 219 colour bars for the frame's matrix |
| `showsSkinToneLine`, `skinToneAngle` | `true`, 123° | 0…360 | 123° is the NTSC I axis in the U/V plane, the line most component vectorscopes draw (**convention** on a Cb/Cr plot) |

HDR graticules: PQ ticks in cd/m² from SMPTE ST 2084 (0.1 to 10 000), HLG ticks for a 1000 cd/m² display (BT.2100), BT.2408 reference levels (18 % grey 26 cd/m², reference white 203). `ScopeIREScale` and `ScopeIREScaleView` draw the −10, 0, 50, 100, 110 IRE labels of either axis in SwiftUI.

### 3.3 Statistics (`ScopeStatistics`, `ScopeStatisticsReader`)

Each accumulation also measures, on the GPU, the stage luma minimum, maximum and average, the fraction of pixels clipped high and low per R, G, B and luma, and the histogram's peak bin. They land in a small shared buffer that any thread reads without stalling the frame path (a seqlock read). No frame data is read back.

## 4. Focus

### 4.1 Peaking (`MonitorState.focus`, `FocusSettings`)

Follows: FX3 Peaking (Level High/Mid/Low; colours red, yellow, blue, white) and Video Assist Focus Assist (coloured edge lines or traditional "Peak", sensitivity Low/Medium/High).

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `enabled` | `false` | | |
| `style` | `.coloredEdges` | `.coloredEdges`, `.peak` | Edges in the colour, or edges brightened |
| `color` | `.red` | `.red`, `.yellow`, `.blue`, `.white`, `.green` | The FX3's four plus green. The FX3 defaults to white |
| `sensitivity` | 0.5 | 0…1 | 0 finds only the strongest edges, 1 the faintest; Low/Mid/High are 0.25/0.5/0.75. Threshold = 0.02 + (1 − s)·0.3 |
| `noiseRejection` | 0.02 | 0…1 | An edge counts only with this much directional support, rejecting sensor noise |
| `opacity` | 0.85 | 0…1 | |
| `stage` | `.source` | any stage | Source: the camera's transport luma. Output/monitor: Rec.709 luma after the LUTs, so a contrasty look peaks what it shows |

Edges are found once per frame per feed, at source resolution (3-10-3 Scharr gradients with a directional-median noise gate, into an r8 mask), and every surface of the feed samples the mask with its own footprint, so a minified picture still shows fine focus. The mask exists only while peaking is on (8.3 MB at 4K). The host calls `MonitorFeed.analyze` before the passes that show peaking; a surface whose stage has no analysis for the frame reports `.focusNotAnalyzed`.

### 4.2 Magnify (`MonitorState.geometry.magnification`, `Magnification`)

Follows: FX3 Focus Magnifier (×1, ×4 steps, pannable; markers hidden while magnified) and Video Assist zoom (double-tap 2×, pinch for variable zoom, drag to pan, an inset showing the position).

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `zoom` | 1 | 1…64 | Over fit |
| `pixelExact` | `false` | | One picture pixel per display pixel (1:1), ignoring `zoom` |
| `centerX`, `centerY` | 0.5 | 0…1 | The point kept at the view's centre, as fractions of the clean aperture (`MonitorLayout.pictureFraction`), clamped so the view never shows past the picture |
| `showsNavigator` | `true` | | The inset showing the whole picture and the visible region |

- Sampling is sharp: nearest at 1:1, Catmull-Rom bicubic when magnified, a box filter when minified.
- Guides are hidden while magnified (`.hiddenWhileMagnified`), as the FX3 hides its markers. Zebras, false colour and peaking stay correct at any zoom.
- `MonitorMagnifier` turns gestures into `Magnification` edits (zoom about a point, pan, toggle 1:1, recentre); `MonitorMetalView` wires pinch, scroll, drag, double click and, on macOS, + / − / 0 and the arrow keys. `MonitorMagnifyChoice` offers fit, 1:1, 2×, 4× and 8×.

### 4.3 Monochrome (`MonitorState.display.monochrome`)

Follows: Video Assist Blue Only. `.blueOnly` shows the blue channel in greyscale (for noise and focus); `.luma` shows a true Rec.709 luma monochrome picture. Default `.off`.

## 5. Framing

All guides are drawn analytically in the picture shader: anti-aliased, pixel-exact at any size, with no line textures.

### 5.1 Guides (`MonitorState.guides`, `GuideSettings`)

Follows: FX3 Aspect Marker, Safety Zone, Grid Line and Center Marker; Video Assist Frame Guides and Grids. Every grid combines freely (the Video Assist does not allow crosshairs with a centre dot).

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `enabled` | `false` | | Master switch for every guide below |
| `frameGuides` | `[]` | up to 4, aspect 0.1…10 | `FrameGuide(aspect:style:matteOpacity:)`; style `.lines`, `.matte` or `.linesAndMatte`; `matteOpacity` 0.6 (0…1) |
| `safeAreas` | `[]` | up to 4, 10…100 % | e.g. 80, 90, 93 |
| `followsFrameGuide` | `true` | | Safe areas and grids follow the first frame guide |
| `thirds` | `true` | | Rule of thirds |
| `squareGrid`, `squareGridRows` | `false`, 4 | 2…16 rows | Columns follow the frame's aspect |
| `diagonals` | `false` | | With the square grid: the FX3's "Diag. + Square Grid" |
| `centerCross`, `centerDot` | `false`, `false` | | |
| `color` | white | | |
| `opacity` | 0.65 | 0…1 | |
| `contrast` | 1 | 0…1 | 0 plain lines; 1 adds a full dark outline so lines read on bright scenes |
| `lineWidth` | 1 | 0.5…8 points | Scaled by `pixelsPerPoint` |

`FrameGuide.standardAspects` is the union of both devices' ratios plus 2.40: 9:16, 4:5, 1:1, 4:3, 13:9, 14:9, 15:9, 16:9, 17:9, 1.66, 1.85, 1.91, 2:1, 2.35, 2.39, 2.40. Any other aspect is a custom guide.

### 5.2 De-squeeze and flip (`MonitorState.geometry`, `ViewGeometry`)

| Parameter | Default | Range | Follows |
| --- | --- | --- | --- |
| `desqueeze` | 1 | 1…4 | FX3 De-Squeeze Display (1.3, 1.5, 1.6 applied as 1.65, 2.0) and Video Assist (1.33, 1.5, 1.66, 2); `ViewGeometry.standardDesqueezeFactors` = 1, 1.3, 1.33, 1.5, 1.65, 1.66, 1.8, 2 |
| `flip` | `.none` | `.none`, `.horizontal`, `.vertical`, `.rotate180` | FX3 Monitor Flip (mirror, 180°) and Video Assist rotation (180°) |

### 5.3 Picture geometry

The picture follows the frame's own geometry: its pixel aspect ratio and its clean aperture (`MonitorFrame.cleanAperture`, read from CoreVideo's attachment by `wrap`, or set by the host to crop to any region of interest). The layout, fit, magnification, guides and navigator follow the aperture; analysis and scopes still cover the whole frame. A pixel aspect ratio outside 1/16…16 is drawn as square pixels and reported (`.unsupportedGeometry`). `MonitorLayout(frame:state:viewport:)` and `MonitorFrameGeometry.displayAspectRatio(for:)` give a host the layout and display aspect on any thread, before encoding (for sizing a layer).

## 6. Colour pipeline

### 6.1 LUTs (`MonitorLUT`, `MonitorFeed.burnInLUT` / `.monitorLUT`)

Follows: FX3 Display LUT (monitor-only) and PPLUT (recorded, "baked in"), Video Assist Display 3D LUT (monitor-only).

| Item | Value |
| --- | --- |
| File format | Adobe/Resolve `.cube`: `LUT_3D_SIZE` 2…65 (2, 17, 33 and 65 tested), `LUT_1D_SIZE` up to 65536 entries as a 1D-only LUT or a shaper before a 3D table, `DOMAIN_MIN`/`DOMAIN_MAX` or `LUT_1D_INPUT_RANGE`/`LUT_3D_INPUT_RANGE`, `TITLE` (`CubeLUT(text:)`) |
| Interpolation | `.tetrahedral` (default: four lattice reads, neutrals stay neutral), `.trilinear` (eight reads, bit-compatible with Ultracam's original LUT shader), `.hardware` (the texture filter; fastest, 8 fractional bits; falls back to trilinear where 32-bit float filtering is missing) |
| Routing | `burnInLUT`: the output stage, and every preview of it; a host that burns the LUT into its output calls `mk_applyLUT` with the same `MonitorLUT`, so preview and output match. `monitorLUT`: the monitor stage only, stacked on the burn-in LUT, never in output. `MonitorState.monitorLUT` (default `true`) lets a surface skip the monitor LUT. `LUTRouting` names the two |
| Output | Rec.709 display R'G'B' (`LUTOutputEncoding.rec709`, the only encoding modelled): a LUT stage is a Rec.709 SDR picture, weighted as Rec.709 |

Zebras, false colour, peaking, guides and every other tool never reach output in either routing.

### 6.2 Picture stage (`MonitorState.pictureStage`)

Default `.monitor` (after both LUTs). `.output` shows what the output carries (the burn-in LUT, not the monitor LUT); `.source` shows the camera signal with no LUT, so a display transform can apply even while the feed burns a LUT in. Tools keep measuring their own stages.

Each stage reads the codes its own way when they differ (`SignalDescription.outputReading`, a `SignalReading` of range and matrix): the Source stage with the camera's declared reading (`range`, `matrix`), the Output and Monitor stages, with or without a LUT, with the reading the host's burn-in and real output use. For a camera declared full range on a legal-range link, a Source zebra at 100 % marks code 1023 while an Output one marks 940; for a SMPTE 240M source whose output path decodes BT.709, the Output stage's vectorscope and clip indicators read BT.709. Pictures, zebras, clip indicators, false colour, peaking and scopes all follow it, in the same pass. It costs one more decode only where a drawn tool reads the Output or Monitor stage (about +7 % of a 4K picture with zebras and clip indicators there), nothing otherwise. A log or unlabelled signal shown on a stage no LUT touched, with no display transform, is a code-value view: `MonitorStatus.isCodeValueView` is set and the `.picture` status entry says so ("Source · S-Log3 code values").

### 6.3 Display transforms (`MonitorState.displayTransform`, `DisplayTransformSettings`)

Follows: FX3 Gamma Display Assist (S-Log3→709(800%), HLG(BT.2020), HLG(709); locked off while a LUT applies) and the Video Assist's HDR monitoring. Monitor-only, after the monitor LUT; not an overlay, so a clean surface keeps it.

| Mode | What it does |
| --- | --- |
| `.none` | The default |
| `.logToRec709` | S-Log3 (S-Gamut3, S-Gamut3.Cine), LogC3 (AWG3) or LogC4 (AWG4) to Rec.709 SDR: "MonitorKit display assist v1". Per-channel log decode, camera gamut to Rec.709 in scene light, the BT.709 OETF to a 70 % knee, then a slope-matched shoulder. 18 % grey lands at 40.9 % for every camera, a 90 % white card at 85.4 % |
| `.hdrToSDR` | PQ: the BT.2408 Annex 5 EETF from `pqSourcePeak` to graphics white (203 cd/m²) on maxRGB, then BT.2020 → BT.709 (BT.2407 §2) and BT.1886. HLG: Report ITU-R BT.2446-1 Method C on the 1000 cd/m² display light, a linear segment then a logarithmic knee on the luminance at constant chromaticity (18 % grey, 38 % HLG → 53.2 % SDR; skin, 50 % → 70 %; HDR reference white, 75 % → 96 %; 100 % SDR from about 82.9 % HLG), then BT.2020 → BT.709 (BT.2407 §2) and BT.1886 |
| `.hdrPassthrough` | PQ or HLG stays HDR on an HDR output, highlights rolled off (EETF) to what the output holds: the EDR headroom × reference white for extended linear, `hlgNominalPeak` for HLG |

`pqSourcePeak`: 1000 cd/m² (100…10 000), the PQ master's peak. A transform needs the camera's signal: with a LUT on the picture's stage it reports `.lutOnMonitorStage`; HDR modes need a PQ or HLG source (`.requiresHDRSource`); passthrough needs an HDR output (`.requiresHDROutput`).

### 6.4 Display adjustments (`MonitorState.display`, `DisplayAdjustments`)

Follows: Video Assist Brightness, Contrast, Saturation and LCD temperature and tint calibration; FX3 Monitor Brightness. They change the monitor picture only, never output, tools or legends.

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `brightness` | 0 | −1…1 | Added to every channel |
| `contrast` | 1 | 0…2 | Gain about mid-grey (0.5) |
| `saturation` | 1 | 0…2 | 0 greyscale, 2 doubled |
| `temperature` | 6504 K | 4000…10 000 K | White-point trim: the white is moved to this point on the CIE daylight locus (6504 K is D65, no trim) |
| `tint` | 0 | −0.02…0.02 | Δuv off the locus (CIE 1960 uv, ANSI C78.377 sign: positive greener) |
| `monochrome` | `.off` | `.off`, `.luma`, `.blueOnly` | Section 4.3 |

The trim is applied in linear display light after brightness, contrast and saturation, and costs nothing when off.

### 6.5 Output colour and HDR (`MonitorPass.outputColor`, `MonitorOutputColor`)

Follows: the Video Assist's HDR handling (HDR detection, HDR format override) on Apple's EDR displays. The host declares the frame's signal (which is the Video Assist's override: Rec.709, Rec.2020 SDR, HLG or ST 2084 at a stated peak), and the output colour says what the target's values mean.

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `encoding` | `.signalNative` | `.signalNative`, `.sdr(.bt1886 / .sRGB / .gamma22)`, `.extendedLinear`, `.pq`, `.hlg` | Signal-native writes the picture's own R'G'B' untouched; tag the layer with its colour space and Core Animation colour-matches and tone-maps it |
| `primaries` | `.rec709` | `.rec709`, `.displayP3`, `.rec2020` | Of explicit encodings |
| `referenceWhite` | 203 cd/m² | 48…1000 | Graphics white: where SDR white and overlays land in HDR (BT.2408) |
| `hlgNominalPeak` | 1000 cd/m² | 100…10 000 | Only the target PQ-to-HLG passthrough rolls off to (HLG is always encoded for its 1000 cd/m² reference display) |
| `headroom` | 1 | 1…64 | The display's EDR headroom; a uniform, so changing it rebuilds nothing |

`MonitorOutputColor.layer(for:displayTransform:monitorStageHasLUT:)` returns the `MonitorLayerColor` to tag a `CAMetalLayer` with: `bgr10a2Unorm` or `rgba16Float`, the named `CGColorSpace`, the EDR flag and suggested `CAEDRMetadata` (HDR10 at 1000 cd/m² for PQ, HLG for HLG). MonitorKitUI's `apply(to:)` configures the layer, building an exact power-law ICC space where Core Graphics names none (BT.1886 on Display P3, gamma 2.2). Overlays are written at graphics white, 58 % PQ or 75 % HLG on HDR layers.

## 7. Status and output

| Feature | API | Follows |
| --- | --- | --- |
| Clean feed | `MonitorState.clean` (one surface) and `MonitorScene.clean` (a whole view): every overlay and analysis off, LUTs, display transform, adjustments and geometry kept | Video Assist Clean Feed |
| Status overlay | `MonitorStatusOverlay` with `MonitorOverlayMetadata`: timecode, format, LUT name, tally (`.off`, `.preview`, `.program`, `.recording`, drawn as a border) and labels in four corners; `MonitorOverlayModel` for values that change every frame. SwiftUI text, never burned into frames | FX3 Emphasized REC Display and info, Video Assist status bar |
| Tool status | `MonitorStatus`: active entries with labels (`activeLabels`), unavailable tools with a `MonitorUnavailableReason`, `pictureStage`, `isCodeValueView` | |
| Pipeline warm start | `MonitorEngine(…, cacheDirectory:)`, `ScopeEngine(…, cacheDirectory:)`, `MonitorPipelineArchive`: pipelines compiled once are kept as Metal 4 archives in the host's caches directory and loaded at the next launch instead of compiling (keyed by shader source, GPU and OS build; damaged files ignored; identical pixels) | Plan feature |
| Freeze | `MonitorFeed.freeze(_:into:)`: one compute copy of the frame's planes into feed-owned textures (22.3 MB for 4K v210, made only on request and reused), usable wherever a live frame is; `unfreeze(keepingMemory:)`. The state machine (pending, frozen) stays the host's; `MonitorFreezeState` labels the button | Plan feature (neither device) |
| Multiview | `MonitorMultiview`: several surfaces, each with its own tools, in one render pass | Plan feature |
| Tile toolbar | `MonitorTileToolbar`: per-tool toggles and settings menus for guides, zebra, false colour, peaking, clip indicators, magnify and clean; scopes and Freeze through host callbacks | Ultracam's monitor chrome |
| Controls | `ZebraControls`, `FalseColorControls`, `PeakingControls`, `GuideControls`, `GeometryControls`, `DisplayAdjustmentControls`, `LUTRoutingControls`, `OutputColorControls`, `ClipIndicatorControls`, `CleanSwitch`: SwiftUI editors of `MonitorState` through `normalized()` | |

## 8. Audio

Follows: the Video Assist's meters (VU at −18 or −20 dBFS, PPM at −18 or −20 dBFS with peak hold, up to 16 channels) and the FX3's level meter, extended to broadcast metering: BS.1770 true peak and EBU R 128 loudness. Pure Swift and Accelerate on the host's audio thread, with no GPU work.

`AudioMeterConfiguration`:

| Parameter | Default | Range | Meaning |
| --- | --- | --- | --- |
| `sampleRate` | | 8 kHz…768 kHz | |
| `channelCount` | | 1…16 (`audioMeterMaximumChannelCount`) | |
| `meters` | `.all` | `.samplePeak`, `.truePeak`, `.rms`, `.vu`, `.ppm`, `.loudness` | Turning one off removes its work |
| `peakHoldTime` | 2 s | `.infinity` holds until reset | Peak-hold markers |
| `peakDecayRate` | 20/1.7 dB/s | | IEC 60268-18 return, 20 dB in 1.7 s |
| `clipLevelDBFS` | −0.01 | | Samples at or above count as clipped |
| `vuReference` | `.ebu` (−18 dBFS) | `.ebu`, `.smpte` (−20), any `AlignmentLevel` | 0 VU |
| `vuBallistics` | `.iec60268_17` | | 300 ms to 99 %, 1.25 % overshoot |
| `ppmType` | `.typeIIb` (EBU) | `.typeI` (DIN), `.typeIIa` (BBC), `.typeIIb` | IEC 60268-10 ballistics and scale |
| `customPPMBallistics` | nil | | A national variant |
| `ppmAlignment` | `.ebu` | | The PPM's alignment mark |
| `rmsWindow`, `rmsScale` | 0.3 s, `.aes17` | | AES17 adds 3.01 dB so a sine reads its peak level |
| `loudnessChannels` | the standard layout | one `LoudnessChannel` per channel | Mono, stereo, 5.0, 5.1 by count (BS.1770 Table 3 weights; LFE excluded); other counts measure channels 1–2 as stereo; presets include SMPTE 7.1; `.excluded` leaves a channel out (another language pair) |
| `publishInterval` | 5 ms | ≥ 0 | Readings are published at most this often; peaks, maxima and clip counts lose nothing in between |

Readings per channel (`AudioChannelLevels`): sample peak and hold, true peak (BS.1770 Annex 2, 4× oversampled below 96 kHz and 2× above) with hold and maximum, RMS, VU, PPM, clip count. Loudness (`LoudnessSnapshot`): momentary (400 ms), short-term (3 s), integrated (gated, BS.1770), loudness range (EBU Tech 3342), maximum momentary and short-term, duration. `programmeMaximumTruePeak` is R 128's "Max TP" over the programme channels. Measurement control: `pauseLoudness` / `resumeLoudness` (EBU Tech 3341 stand-by), `resetLoudness`, `resetPeaks`, `reset`, and `flush()` when a stream stops. `LoudnessMeter` is the loudness engine alone.

`MeterScale` gives each meter's marks and zones: IEC 60268-18 digital peak, the IEC 60268-17 VU face, each PPM type's scale (and the Nordic one), and the EBU +9 / +18 loudness scales in LU or LUFS. `AudioMeterView` (MonitorKitUI) draws the bars, peak holds, clip LEDs and the R 128 panel.

## 9. Why a tool is not drawn

A tool that is on but cannot run on the frame's signal is skipped with a reason in `MonitorPass.status`; the picture is always drawn.

| Reason | Tools | When |
| --- | --- | --- |
| `.cleanFeed` | every overlay | `MonitorState.clean` is on |
| `.requiresLogSource` | log false colour, `.logToRec709` | The frame is not labelled as log |
| `.unsupportedLogEncoding(_)` | log false colour | A log encoding the mode does not classify (e.g. the ARRI tables on S-Log3, Sony Pattern 2 on LogC) |
| `.noBands` | custom false colour | No bands |
| `.requiresKnownTransfer` | custom false colour in stops | The transfer is unlabelled (and no LUT produces the measured stage) |
| `.focusNotAnalyzed` | peaking | No analysis of this frame on this surface's stage |
| `.hiddenWhileMagnified` | guides | Magnified |
| `.requiresHDRSource` | `.hdrToSDR`, `.hdrPassthrough` | Neither PQ nor HLG |
| `.requiresHDROutput` | `.hdrPassthrough` | The output is SDR |
| `.lutOnMonitorStage` | display transforms | A LUT produces the picture's stage |
| `.requiresCameraSignal` | log false colour, peaking | `MonitorFrame.isProcessed` (a programme mix, a scaled or graded render) |
| `.unsupportedGeometry` | `.picture` | The pixel aspect ratio is not finite or outside 1/16…16 (shown square) |

## 10. Out of scope

These need camera metadata or sensors a monitor input does not carry: level gauge, EI, shutter, ISO and aperture readouts, Focus Map (depth), Bright Monitoring, face and eye frames, the FX3's EI preview. A host that has these values can show them in `MonitorStatusOverlay` labels. Sony Pattern 1 (SDR) false colour is not implemented, nor are HDR-output LUTs (any LUT makes the picture Rec.709).
