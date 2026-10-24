# MonitorKit math reference

Every constant and formula MonitorKit uses, with its primary source and whether it was checked against that source. Most checks live in `Tests/MonitorKitCoreTests/MathReferenceTests.swift` (named below without a prefix). Each of those tests re-derives values from the source definition; none copies the value from the implementation. Checks in other test targets are named with their file (`LoudnessTests.…`).

Status:
- **verified**: matches the primary source, and the named test checks it.
- **verified by reading**: matches the source on inspection; no test checks it yet.
- **discrepancy**: differs from the source. Section 9 lists every case with its fix.
- **fixed**: a former discrepancy, corrected (2026-10-22); section 9 keeps the record and names the regression test.
- **convention**: MonitorKit's own choice where no source defines one. It is labelled in code.
- **unverifiable**: no primary definition is published. The reason is given.
- **reference only**: pinned here and in a test for a feature that is not implemented yet. Nothing is in this state since W2: the display transforms, BT.1886 and the gamut matrices now ship.

Code locations name files and symbols. The shader files are changing, so MSL locations name functions, not line numbers.

Research date: 2026-10-22 (W1); W2 additions (output colour, display transforms, white-point trim, scope HDR colours, audio rate rules) the same day. W3 addition: picture geometry (clean aperture, pixel aspect ratio, display aspect), section 12.

## Sources

| ID | Document | Where | SHA-256 of the copy read |
| --- | --- | --- | --- |
| SONY-TS | Sony, *Technical Summary for S-Gamut3.Cine/S-Log3 and S-Gamut3/S-Log3* | [pro.sony PDF](https://pro.sony/s3/cms-static-content/uploadfile/06/1237494271406.pdf). The live URL returns 403 to scripts, so the copy read was the [Wayback copy](https://web.archive.org/web/2023/https://pro.sony/s3/cms-static-content/uploadfile/06/1237494271406.pdf) | `d9c8a042…80d5d3` |
| SONY-MC | Sony Monitor & Control help guide, *Shooting assist functions* (False color, EL Zone) | [helpguide.sony.net](https://helpguide.sony.net/promobile/mc/v1/en/contents/shooting_assist_functions.html) | `2c13ff90…a3d548` (HTML) |
| SONY-XLSX | Sony, `S-Gamut3_S-Gamut3Cine_Matrix.xlsx` (Sony community), as transcribed by colour-science `colour/models/rgb/datasets/sony.py` | [colour sony.py](https://github.com/colour-science/colour/blob/develop/colour/models/rgb/datasets/sony.py) | `ea9d0fc2…6b45e2c` |
| ARRI-C3 | ARRI, *ALEXA Log C Curve – Usage in VFX* (H. Brendel, 2017-02-24) | [arri.com PDF](https://www.arri.com/resource/blob/31918/66f56e6abb6e5b6553929edf9aa7483e/2017-03-alexa-logc-curve-in-vfx-data.pdf) | `348d2761…f1b665` |
| ARRI-C4 | ARRI, *ARRI LogC4 Logarithmic Color Space – Specification* (2022) | [AFC mirror](https://www.afcinema.com/IMG/pdf/9/2/e/arri_logc4_specification.pdf) | `c7a254f0…3060a` |
| ARRI-FC | ARRI, *ARRI LogC False Color – Exposure Zones and Key – Specification*, version 2025-02-04 | [arri.com PDF](https://www.arri.com/resource/blob/390448/871b733469a2f2c2099ca51b1516bcd1/arri-logc-false-color-specification-data.pdf) | `463dadba…be725a` |
| BT601 | ITU-R BT.601-7 (03/2011) | [itu.int PDF](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.601-7-201103-I!!PDF-E.pdf) | `d0c31625…0945ce` |
| BT709 | ITU-R BT.709-6 (06/2015) | [itu.int PDF](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.709-6-201506-I!!PDF-E.pdf) | `1fd8567e…47648` |
| BT1886 | ITU-R BT.1886-0 (03/2011) | [itu.int PDF](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.1886-0-201103-I!!PDF-E.pdf) | `bbad0f43…d06ad` |
| BT2020 | ITU-R BT.2020-2 (10/2015) | [itu.int PDF](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2020-2-201510-I!!PDF-E.pdf) | `eed65cf7…03374` |
| BT2100 | ITU-R BT.2100-3 (02/2025) | [itu.int PDF](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2100-3-202502-I!!PDF-E.pdf) | `f0668803…412c3` |
| BT2408 | Report ITU-R BT.2408-8 (2024) | [itu.int PDF](https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2408-8-2024-PDF-E.pdf) | `6eeff425…b4d52` |
| BT2087 | ITU-R BT.2087-0 (10/2015), colour conversion from BT.709 to BT.2020 (§2.2, matrix M2) | [itu.int](https://www.itu.int/rec/R-REC-BT.2087) | — |
| BT2407 | Report ITU-R BT.2407-0 (10/2017), colour gamut conversion from BT.2020 to BT.709 (§2.2 eq. 1, §2.4; Annex 5 evaluated, 5.1) | [itu.int PDF](https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2407-2017-PDF-E.pdf) | `14d626ee…b2fb676` |
| BT2446 | Report ITU-R BT.2446-1 (03/2021), methods for conversion of HDR content to SDR content and vice versa (Table 1; §4.1 Method A; §6.1 Method C) | [itu.int PDF](https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2446-1-2021-PDF-E.pdf) | `c1571348…efb285` |
| EG432 | SMPTE EG 432-1:2010, Display P3 primaries (used with a D65 white). Paywalled; the primaries are the ones Apple publishes for Display P3 | — | — |
| CIE15 | CIE 15:2004 *Colorimetry*, §3.1 daylight locus (eqs 3.3, 3.4); ANSI C78.377 for Duv | — | — |
| H273 | ITU-T H.273 (coding-independent code points), chroma_sample_loc_type 0–5. Used for the siting definitions only; they are also in the HEVC/AVC VUI and CoreVideo's `kCVImageBufferChromaLocation_*` | [itu.int](https://www.itu.int/rec/T-REC-H.273) | — |
| ST2084 | SMPTE ST 2084:2014. Paywalled. Its constants are reproduced exactly in BT2100 Table 4, and that copy was used. | — | — |
| SRGB | IEC 61966-2-1:1999. Paywalled. The piecewise definition is the one reproduced in W3C CSS Color 4 (predefined sRGB). | — | — |
| RP177 | SMPTE RP 177-1993 §3.3, normalized primary matrix from xy primaries and white. Used as the derivation method. | — | — |
| NTSC-IQ | SMPTE 170M / FCC 47 CFR 73.682(a)(20): I = 0.5959R′ − 0.2746G′ − 0.3213B′, the I axis 33° from V in the U/V plane (U = 0.492111(B′−Y′), V = 0.877283(R′−Y′)) | [eCFR 73.682](https://www.ecfr.gov/current/title-47/chapter-I/subchapter-C/part-73/subpart-E/section-73.682) | — |
| BS1770 | ITU-R BS.1770-5 (11/2023). The -4 URL returns 404 now. The coefficients in Annexes 1 and 2 are unchanged from -4. | [itu.int PDF](https://www.itu.int/dms_pubrec/itu-r/rec/bs/R-REC-BS.1770-5-202311-I!!PDF-E.pdf) | `eefb926f…d2f8e` |
| R128 | EBU R 128-2023 | [tech.ebu.ch](https://tech.ebu.ch/docs/r/r128.pdf) | `4292cd23…ca28` |
| T3341 | EBU Tech 3341-2023 (V4) | [tech.ebu.ch](https://tech.ebu.ch/docs/tech/tech3341.pdf) | `dd5a7b0b…1619e` |
| T3342 | EBU Tech 3342-2023 (V4) | [tech.ebu.ch](https://tech.ebu.ch/docs/tech/tech3342.pdf) | `a12cb59f…a89d8` |
| IEC268-10 | IEC 60268-10:1991, peak programme meters (Types I, IIa, IIb). Paywalled. Values taken from the secondary WIKI-PPM, which cites it and EBU Tech 3205 | [IEC webstore](https://webstore.iec.ch/publication/1213) | — |
| IEC268-17 | IEC 60268-17:1990, standard volume indicators (VU; same ballistics as ANSI C16.5-1942). Paywalled. Values from WIKI-VU | — | — |
| IEC268-18 | IEC 60268-18:1995, digital peak level meters. Paywalled. Values from WIKI-PPM | — | — |
| WIKI-PPM | Wikipedia, *Peak programme meter*, revision 1376057041 (2026-09-21), raw wikitext. Secondary | [en.wikipedia.org](https://en.wikipedia.org/w/index.php?title=Peak_programme_meter&oldid=1376057041) | `f753ad4e…464fb6` |
| WIKI-VU | Wikipedia, *VU meter*, revision 1374995076 (2026-09-15), raw wikitext. Secondary | [en.wikipedia.org](https://en.wikipedia.org/w/index.php?title=VU_meter&oldid=1374995076) | `c03c8433…b75c94` |
| R68 | EBU R 68-2000: alignment level −18 dBFS. Cited through WIKI-PPM's table | — | — |
| RP155 | SMPTE RP 155: reference level −20 dBFS. Paywalled. Cited through WIKI-PPM's table | — | — |
| ISOBMFF | ISO/IEC 14496-12 (ISO base media file format), `clap` (CleanApertureBox) and `pasp` (PixelAspectRatioBox), as used by QuickTime and CoreVideo (`kCVImageBufferCleanApertureKey`, `kCVImageBufferPixelAspectRatioKey`). Paywalled; the box semantics are reproduced in Apple's QuickTime File Format Specification ("Clean aperture", "Pixel aspect ratio") | [Apple QTFF](https://developer.apple.com/documentation/quicktime-file-format) | — |
| OCIO | OpenColorIO `SonyCameras.cpp` / `ArriCameras.cpp` (ASF). Secondary; used to cross-check primaries only. | [GitHub](https://github.com/AcademySoftwareFoundation/OpenColorIO/tree/main/src/OpenColorIO/transforms/builtins) | `8be9c5db…cec74` |

## 1. Transport: Y'CbCr, quantization, chroma siting, native log codes

| Item | Value used | Where | Source | Status |
| --- | --- | --- | --- | --- |
| BT.601 kr, kg, kb | 0.299, 0.587, 0.114 | `ColorAnalysis.swift` `YCbCrMatrix` | BT601 §2.5.1. Cb, Cr divisors 1.772 and 1.402 | verified (`testRec709And2020…`, `testYCbCrDecode…`) |
| BT.709 kr, kg, kb | 0.2126, 0.7152, 0.0722 | same | BT709 item 3.2. Cb = (B'−Y')/1.8556, Cr = (R'−Y')/1.5748 | verified (same tests) |
| BT.2020 kr, kg, kb | 0.2627, 0.6780, 0.0593 | same | BT2020 Table 4 and BT2100 Table 6. Divisors 1.8814 and 1.4746 | verified (same tests) |
| Decode | R = Y + 2(1−kr)Cr; B = Y + 2(1−kb)Cb; G = (Y − kr·R − kb·B)/kg | `ColorMath.yCbCrToRGB`, `MKDecode.msl mk_ycbcrToRGB` | Inverse of the recommendation encode | verified (`testYCbCrDecodeInvertsTheRecommendationEncode`, random round trips to 1e−12, all 3 matrices). GPU = CPU: `DecodeTests.testEveryYCbCrLayoutDepthRangeMatrixAndSitingFromRawTextures` |
| Narrow-range quantization | luma (219E'+16)·2ⁿ⁻⁸, chroma (224E'+128)·2ⁿ⁻⁸ | `CodeRange.normalizeLuma/normalizeChroma/levels`, `MKDecode` via `levels` | BT709 item 3.4; BT2100 Table 9 (10/12-bit): 64/940/512/960, 256/3760/2048/3840 | verified (`testQuantizationMatchesBT709AndBT2100Table9`). BT.2100 defines only 10/12-bit; 8-bit is BT.709's, and 16-bit 4096/60160 is the formula's extension, the one CoreVideo's 16-bit video range uses |
| Full-range quantization | luma (2ⁿ−1)E', chroma (2ⁿ−1)E' + 2ⁿ⁻¹ | same | BT2100 Table 9 "Full" | verified (same test). Chroma −0.5 rounds to code 1 (Round = sign·floor(\|x\|+0.5)) |
| `levels` vs `normalize*` | identical mapping | `Signal.swift CodeRange.levels` | — | verified at 8/10/12/16 bits, both ranges (same test) |
| 4:2:2 horizontal siting | `left`: chroma at luma x = 2i (H.273 type 0/2/4); `center`: at 2i + 0.5 (type 1/3/5) | `ChromaSiting`, `DecodeReference.chromaTaps`, `MKDecode.msl mk_chromaCode` | BT709 item 4.3 ("first colour-difference samples co-sited with the first luminance sample"), BT2100 Table 8, H273 | verified: CPU against H.273 (`testChromaTapsMatchH273Siting`); GPU = CPU (`DecodeTests.testEveryYCbCrLayoutDepthRangeMatrixAndSitingFromRawTextures`) |
| 4:2:0 vertical siting | chroma row j at luma row 2j + 0.5 + offset: `center` 0 (types 0/1), `top` −0.5 (types 2/3), `bottom` +0.5 (types 4/5) | `ChromaVerticalSiting`, `DecodeReference.chromaTaps(vertical:)`, `MKDecode.msl mk_chromaCode` (`FrameParameters.matrix.w`), `MonitorFrame.signal(of:)` (all six CoreVideo locations) | H273; BT2100 Table 8 and BT2020 specify type 2 (top-left) | verified: all six types (`testChromaTapsMatchH273Siting`); GPU = CPU (`DecodeTests.testEveryVerticalChromaSitingOf420`, `testChromaLocationAttachmentsMapBothAxes`). **Fixed** (9.3) |
| SMPTE 240M kr, kg, kb | 0.212, 0.701, 0.087 | `YCbCrMatrix.smpte240m`, `MonitorFrame.signal(of:)` | SMPTE ST 240 | verified by reading; GPU decode: `DecodeTests.testSMPTE240MMatrix`. **Fixed** (9.4: it was decoded as BT.601) |
| Native log code, legal container, `.native` | (e·876 + 64)/1023 | `DecodeReference.nativeLog`, `MKDecode.msl mk_nativeLog` | SONY-TS Q4: S-Log3 code values are stored verbatim, 64…940 = 0…100 %. Narrow-range levels scale by exactly 2ⁿ⁻⁸ and a camera's 10-bit code by 2ⁿ⁻¹⁰, so e = (c₁₀ − 64)/876 at every depth and the result is exactly c₁₀/1023 | verified at 8/10/12/16 bits (`testNativeLogLegalAndFullNativeAreExactAtEveryDepth`: 8-bit code 105 and 12-bit code 1680 both give 420/1023). Do not change it. Applies to code-valued curves (S-Log3) only; LogC uses `LogCurve.signal`, which returns e (9.7, fixed) |
| Native log code, legal container, `.fullRescaledToLegal` | e | same | full-range camera codes squeezed into the container's legal range | verified at every depth (same test) |
| Native log code, full container, `.native` | e | same | full-range codes are (2ⁿ − 1)·t (BT2100 Table 9) | verified at every depth (same test) |
| Native log code, full container, `.fullRescaledToLegal` | t = (e·M − 16s)/(219s), s = 2ⁿ⁻⁸, M = 2ⁿ − 1 of the container ((e·1023 − 64)/876 at 10 bits; float RGB counts as 10-bit) | `DecodeReference.nativeLog(bitDepth:)`, `DecodeReference.unsqueezeLegal`, `LogCurve.signal(bitDepth:)`, `MKDecode.msl mk_unsqueezeLegal` (M from `FrameParameters.levels.y`) | legal-squeezed codes in a full container, assuming the squeeze targeted the container's own legal range (as any n-bit legal encode does) | verified at 8/10/12/16 bits (`testNativeLogFullContainerRescaled8Bit/10Bit/12Bit/16Bit`); GPU: `FalseColorTests.testRescaledLogInFullContainersOfEveryDepth`. **Fixed** (9.6) |
| GPU native log | the four branches above | `MKDecode.msl mk_nativeLog` | — | GPU = CPU at every 10-bit code, and the rescaled full branch at 8/12/16 bits (`testShaderCurvesMatchTheCPUReferenceOnTheGPU`, ≤ 1.1e−7) |

## 2. Camera log curves

The MSL versions in `MKMonitor.msl` are compiled from the shader text and run on the GPU at every 10-bit code against the Core curves (`testShaderCurvesMatchTheCPUReferenceOnTheGPU`); worst relative errors: S-Log3 4.4e−7, LogC3 7.7e−7, LogC4 2.1e−6, LogC3 reference encode 2.6e−6. `testShaderCurveConstantsMatchSources` additionally checks that each source constant still appears in the function's brace-matched text; it checks presence only, the GPU test checks the arithmetic.

### Sony S-Log3 (SONY-TS appendix, p.6)

| Item | Value | Where | Status |
| --- | --- | --- | --- |
| Encode, x ≥ 0.01125 | (420 + log10((x + 0.01)/0.19)·261.5)/1023 | `ColorMath.sLog3Encode` | verified to 1e−14 against an independent transcription (`testSLog3MatchesTechnicalSummaryAppendix`) |
| Encode, x < 0.01125 | (x·(171.2102946929 − 95)/0.01125 + 95)/1023 | same | verified (same test) |
| Decode | branch at code ≥ 171.2102946929 | `ColorMath.sLog3Decode`, `LogCurve.sLog3`, `MKMonitor.msl mk_sLog3Decode` | verified (same test; GPU test). The published inverse toe reads `out +` where `out =` is meant (a typo); the code uses the true inverse of the forward toe |
| Breakpoint continuity | the log branch at 0.01125 gives code 171.2102946928606 against the constant 171.2102946929 (4e−11 codes) | — | verified. Value-continuous, not slope-continuous: the slopes are 5344 and 6774 codes per unit, by Sony's design |
| Anchors | 0 → 95, 0.18 → 420 (exact), 0.9 → 597.895 (published Round = 598) | — | verified |
| IRE scale | IRE = (code − 64)/876·100 | `SonySLog3FalseColor.ire`, `MKMonitor.msl mk_logFalseColor` Sony branch | verified by SONY-TS FAQ Q4 (0…1023 is −7…109 IRE, 64…940 is 0…100) and the appendix table (95 = 3.5 %, 420 = 41 %, 598 = 61 %) (`testSonyIREScaleMatchesTechnicalSummary`; the shader expression by `testShaderCurveConstantsMatchSources`; GPU = CPU at every code by `FalseColorTests.testSonyPattern2EveryCode`) |

### ARRI LogC3, EI 800 (ARRI-C3 p.4 formula and the exposure-value table on p.9)

| Item | Value | Where | Status |
| --- | --- | --- | --- |
| Parameters | cut 0.010591, a 5.555556, b 0.052272, c 0.247190, d 0.385537, e 5.367655, f 0.092809 | `LogCurve.arriLogC3`, `SonyARRIStyleFalseColor.referenceCode`, `MKMonitor.msl mk_logC3Decode/mk_logC3ReferenceCode` | verified (EI 800 row of the exposure-value table, not the sensor-signal table) (`testLogC3EI800MatchesARRIWhitePaper`; GPU test) |
| Encode / decode | x > cut ? c·log10(a·x + b) + d : e·x + f; t > e·cut + f ? (10^((t−d)/c) − b)/a : (t − f)/e | same | verified. Both comparisons are strict, as published |
| Signal normalisation | t is range-scaled: legal code = 64 + 876·t, full code = 1023·t | `LogCurve.signal`, `MKMonitor.msl mk_logSignal` | ARRI-FC §3.1 and Table 9 (grey 0.391 is code 400 full, 406.5 legal). Unlike S-Log3, t is not code/1023 in a legal container. verified: `testLogC3ProfileDefaultTransportDecodesLegalGrey` (legal and full grey at 8–16 bits); GPU: `FalseColorTests.testCustomStopsOnLogCFollowARRIsRangeConvention`. **Fixed** (9.7) |
| 18 % grey | 0.3910068 (task anchor 0.391007) | — | verified |
| Breakpoint | e·cut + f = 0.1496578 (table: 0.149658). The log branch starts 2.5e−7 lower | — | verified. With the rounded parameters, an x in (cut, cut + 5e−8] decodes through the linear branch, which causes a 5e−8 round-trip error. This is inherent and documented in the test |

### ARRI LogC4 (ARRI-C4 eqs 1–3, Appendix B)

| Item | Value | Where | Status |
| --- | --- | --- | --- |
| a, b, c | (2¹⁸ − 16)/117.45, (1023 − 95)/1023, 95/1023 | `LogCurve.arriLogC4`, `MKMonitor.msl mk_logC4Decode` | verified (`testLogC4MatchesARRISpecification`; GPU test). Eq. 4 says to use 117.45, the rounded form of 0.18/(400/260991) |
| s, t | 7·ln2·2^(7−14c/b)/(a·b); (2^(14(−c/b)+6) − 64)/a = −0.0180570 | same | verified: s is the inverse slope of the log branch at t, so the curve is C¹ |
| Decode | E' ≥ 0 ? (2^(14(E'−c)/b + 6) − 64)/a : E'·s + t | same | verified (round trip to 1e−11, −0.05…469.8) |
| Signal normalisation | as LogC3: legal code = 64 + 876·E' (Table 25: grey 0.278396 is 284.8 full, 307.9 legal) | same | verified (`testLogC4ProfileDefaultTransportDecodesLegalGrey`; same GPU test). **Fixed** (9.7) |
| Anchors | 18 % → 0.2783958 (task 0.278396; Appendix B 0.2784); 0 → 95/1023; E' = 1 → 469.8; E' = 0 → t | — | verified |
| Hardware curve (eq. 1) | E' = min((log2(a_h·E + 64) − 6)/14·b + c, 1), a_h = (2¹⁸ − 16)·EI/800 | used only in the test | verified (it regenerates the EI 800 false-colour table exactly; see 4.2) |

## 3. Gamuts and scene-linear luminance

Luminance weights are the Y row of the RGB→XYZ matrix, derived with RP177 from xy primaries and D65 (0.3127, 0.3290). Every primary's XYZ column has Y = 1 before scaling, so the Y row equals S = P⁻¹·W.

| Gamut | Primaries (R, G, B) | Derived Y row | Code | Status |
| --- | --- | --- | --- | --- |
| Rec.709 | (0.64,0.33) (0.30,0.60) (0.15,0.06) | 0.212639, 0.715169, 0.072192 | 0.2126, 0.7152, 0.0722 (BT709 rounding) | verified to 5e−5 (`testRec709And2020LuminanceDeriveFromTheirPrimaries`) |
| Rec.2020 | (0.708,0.292) (0.170,0.797) (0.131,0.046) | 0.262700, 0.677998, 0.059302 | 0.2627, 0.6780, 0.0593 | verified to 5e−5 (same test) |
| S-Gamut3.Cine | (0.766,0.275) (0.225,0.800) (0.089,−0.087) (SONY-TS p.7) | 0.215075820115588, 0.885068501743728, −0.100144321859316 | same | verified to 1e−12 (`testSGamut3CineLuminanceDerivesFromSonyPrimaries`). SONY-XLSX row 0.2150758201, 0.8850685017, −0.1001443219 |
| S-Gamut3 (= S-Gamut primaries) | (0.730,0.280) (0.140,0.855) (0.100,−0.050) (SONY-TS p.7) | 0.270979670813492, 0.786606411220905, −0.057586082034398 | same (`ColorGamut.sGamut3`) | verified to 5e−11 (`testSGamut3LuminanceDerivesFromSonyPrimaries`). SONY-XLSX gives 0.2709796708, 0.7866064112, −0.0575860820. **Fixed** (9.1) |
| ARRI Wide Gamut 3 | (0.6840,0.3130) (0.2210,0.8480) (0.0861,−0.1020) | 0.291954, 0.823841, −0.115795 | `ColorGamut.arriWideGamut3` (the LogC3 profile's gamut) | verified to 5e−7 (`testWideGamutLuminanceRowsDeriveFromARRIPrimaries`, `testLogC3ProfileCarriesAWG3Luminance`). Matches the ARRI-C3 appendix matrix. **Fixed** (9.5) |
| ARRI Wide Gamut 4 | (0.7347,0.2653) (0.1424,0.8576) (0.0991,−0.0308) | 0.2545241764, 0.7814777327, −0.0360019091 | `ColorGamut.arriWideGamut4` (the LogC4 profile's gamut) | verified to 1e−10 (same test, `testLogC4ProfileCarriesAWG4Luminance`). Matches ARRI-C4 eq. 5a. **Fixed** (9.5) |

The GPU receives these weights from Core (`MonitorPass` sets `PassParameters.gamutWeights` from `log.gamut.luminanceCoefficients`), so a Core fix also fixes the shader.

### 3.1 Output primaries and conversion matrices (`Colorimetry.swift`)

`ColorPrimaries` (.rec709, .displayP3, .rec2020) carry their chromaticities, the RP177 normalized primary matrix (`ColorMatrix.normalizedPrimaryMatrix`) and `conversion(to:)` = NPM(target)⁻¹ · NPM(source), applied in linear light. Out-of-gamut results are clipped after conversion, except for the extended-linear encoding, which keeps negative and above-white values (never NaN; `OutputColorGPUTests.testOutOfGamutHandling`).

| Item | Value | Status |
| --- | --- | --- |
| BT.709 → BT.2020 | BT2087 M2 [0.6274 0.3293 0.0433; 0.0691 0.9195 0.0114; 0.0164 0.0880 0.8956] | verified to 5e−5 (`OutputColorTests.testRec709ToRec2020IsBT2087`) |
| BT.2020 → BT.709 | BT2407 eq. 1 [1.6605 −0.5876 −0.0728; −0.1246 1.1329 −0.0083; −0.0182 −0.1006 1.1187] | verified to 5e−5 (`testRec2020ToRec709IsBT2407`) |
| NPMs | BT.709 (IEC 61966-2-1 / BT2087 4-decimal matrix), BT.2020 (BT2087 M2's left factor), Display P3 (EG432 primaries R (0.680, 0.320), G (0.265, 0.690), B (0.150, 0.060), D65) | verified (`testNormalizedPrimaryMatricesMatchPublishedValues`) |
| Camera gamut → Rec.709 | the §5.1 matrices, shipped as `ColorGamut.conversion(to:)` | verified (`testCameraGamutConversionsAreThePinnedRP177Matrices`) |

## 4. False colour

### 4.1 Sony Pattern 2 (S-Log3)

| Band | Lower–upper (IRE) | Status |
| --- | --- | --- |
| Red | 93.4–96.1 | verified |
| Orange | 87.7–90.6 | verified |
| Yellow | 91.3–93.4 | verified |
| Cyan | 43.8–46.5 | verified |
| Pink | 54.3–58 | verified |
| Light pink | 47.8–50.8 | verified |
| Green | 38.9–42.2 | verified |
| Light blue | 24.6–34.4 | verified |
| Blue | 3.5–5.6 | verified |
| Purple | −7.0–3.5 | verified |

Source: SONY-MC table "preset values for color palette patterns", Pattern2 (S-Log3) column (`testSonyPattern2TableMatchesMonitorAndControlHelpGuide`). The page does not state units. The IRE scale in section 2 makes them consistent: 18 % grey (40.64) is green, black (3.54) is blue, and the −7.0 floor matches Q4's −7 IRE. The page does not give the band ownership at shared edges. Lower-inclusive, upper-exclusive is a **convention**. Display RGB values are a **convention**. Native codes 0–2 fall below −7.0 IRE (code 0 is −7.31), so they show grey, as the published table implies. Sony also publishes a Pattern1 (SDR) table, which MonitorKit does not implement.

### 4.2 ARRI literal LogC tables (ARRI-FC)

- Achromatic signal: A' = 0.21260·R' + 0.71520·G' + 0.07220·B' on log RGB (eq. 1). Lower bound inclusive, upper exclusive, grey fallback (A',A',A') (eq. 2). Colours from Table 1. **verified** (`testLogC3EI800AnchorsFallInPublishedZones`; `mk_luma709` on the GPU by `testShaderCurvesMatchTheCPUReferenceOnTheGPU`)
- LogC3 EI 800, Table 9:
  - legal: 878–940, 857–878, 461–480, 397–415, 152–172, 64–152
  - full: 951–1023, 926–951, 464–486, 389–410, 103–127, 0–103
  - **verified** by transcription. No derivation is published (§4.1), so these are **unverifiable** beyond the table itself. Plausibility check: 18 % grey (code 400 full, 406.5 legal) is green and one stop over is pink in both tables (`testLogC3EI800AnchorsFallInPublishedZones`).
- LogC4 (ALEXA 35) EI 800, Table 25:
  - legal: 808–940, 789–808, 351–366, 300–315, 149–159, 64–149
  - full: 868–1023, 846–868, 335–353, 276–293, 99–111, 0–99
  - **verified by derivation**: B = f_hw(F/N, EI), N = 260991, sensor bounds from Tables 16/17 (EI-dependent at 800, independent at 400), then Round(). This regenerates every 10-bit bound (`testLogC4EI800FalseColorTableDerivesFromSpecification`).
- §3.1: ARRI SDI is 10-bit legal. "Full" tables are for links scaled legal-to-full.
- Table selection and classified code, `MonitorPass.resolveFalseColor` and `MKMonitor.msl mk_logFalseColor` ARRI branch. The full table is used when the container is full or the transport is rescaled; the code is `full container ? A'·1023 : A'·876 + 64`, then `(code − 64)/876·1023` when rescaled. Traced for all four cells, with c the stored 10-bit code: (legal, native) → c against the legal table; (full, native) → c against the full table; (legal, rescaled) → t·1023 against the full table; (full, rescaled) → t·1023 against the full table. **verified**: each is the ARRI code of the declared transport, and `FalseColorTests.testLiteralARRILogC3AndLogC4EveryCodeInLegalFullAndRescaledTables` checks every code of every cell on the GPU. In an 8/12/16-bit full container with rescaled transport the stored code is first read in the container's own scale, A'·M, and unsqueezed with `mk_unsqueezeLegal` (9.6, fixed; `FalseColorTests.testRescaledLogInFullContainersOfEveryDepth`).

### 4.3 ARRI-style on S-Log3 (MonitorKit adaptation)

Each channel is decoded from S-Log3, then Y uses the source gamut (section 3), then the result is encoded with the LogC3 EI 800 exposure-value curve × 1023 and classified with the full-range Table 9. The **convention** is documented in `docs/MONITOR_COLOR_REFERENCES.md`. The constants are verified (section 2), and so are both Sony gamuts' weights (section 3).

### 4.4 EL Zone (public chart)

Stops = log2(Y) − log2(0.18) + offset. The palette comes from the Panasonic FW9 chart (SHA-256 recorded in `docs/MONITOR_COLOR_REFERENCES.md`). The midpoint transitions are a **convention**. Y uses the source gamut (section 3).

### 4.5 Six-band (display IRE)

| Item | Value | Status |
| --- | --- | --- |
| 18 % grey in BT.709 | OETF(0.18) = 0.4090077 → **40.90 IRE** | verified (`testRec709OETFAndSixBandAnchors`) |
| One stop over | OETF(0.36) = 0.5949590 → **59.50 IRE** | verified (same test); the `SixBandFalseColor` comment now says 59.5. **Fixed** (9.2) |
| Bands | purple < 2.5, blue 2.5–8, green 38.4–43.4, pink 56.4–62.4, yellow 93–99, red ≥ 99 | **convention**. 40.90 and 59.50 both fall inside their bands, and the bands do not overlap (same test). The Blackmagic manual labels green "38.4 %", which is the band's lower edge |

### 4.6 Custom scale in stops (`MKMonitor.msl mk_stageFalseColor`)

Log sources (stage untouched by a LUT): scene-linear Y of the log decode (`mk_logDecode(mk_logSignal(source))`) with the source gamut's `gamutWeights`. verified for S-Log3 (`FalseColorTests.testCustomBandsInIREAndStops`) and LogC3/LogC4 in legal and full containers with both transports (`FalseColorTests.testCustomStopsOnLogCFollowARRIsRangeConvention`; grey reads 0 stops). 9.5 and 9.7 are fixed.

Display sources: each channel is linearised with the source's own transfer, `DisplayTransfer.exposureLinear` / `mk_exposureLinear`, then weighted by the Y'CbCr matrix:
- BT.709: the inverse OETF, `mk_bt709Linear`: V < 0.081 ? V/4.5 : ((V + 0.099)/1.099)^(1/0.45) (scene light).
- sRGB: the IEC 61966-2-1 decode.
- PQ: ST 2084 display light, scaled so BT.2408's grey card (26 cd/m²) is 0.18; reference white reads +2.965 stops.
- HLG: the BT.2100 inverse OETF (scene light), scaled so BT.2408's 38 % grey is 0.18; reference white reads about +2.47 stops (scene-referred; the OOTF would make it display light).
- Linear: the value itself.

verified: `FalseColorTests.testCustomStopsLinearizeWithTheSignalsTransfer` (every transfer, GPU = Core) and `testStopsOnHDRSignalsUseTheirOwnTransfer` (Core against BT.2100/BT.2408). An unlabelled source reports `requiresKnownTransfer`. A LUT-produced stage is Rec.709 display R'G'B' and uses the BT.709 inverse. **Fixed** (9.8).

The published constants leave a 2.5e−4 step at L = 0.018: 4.5·0.018 = 0.081, while the power branch gives 0.0812479. So the inverse is undefined on [0.081, 0.0812479). The 0.081 split is the usual choice; with it, `bt709Linear(0.081)` takes the power branch and returns 0.0179450, not 0.018 (the inverse is not monotonic across the split). BT2020's exact α = 1.09929682680944 and β = 0.018053968510807 remove the step (`testBT2020ExactTransferConstantsSolveItsSimultaneousEquations`). The inversion is scene-referred, which is what the "18 % grey = 40.9 IRE" convention needs.

## 5. Display transfers (output colour, scopes and the sRGB target)

| Item | Definition | Where | Status |
| --- | --- | --- | --- |
| BT.709 OETF | V = 1.099·L^0.45 − 0.099 (L ≥ 0.018), 4.5·L below | test reference; inverse in `ColorMath.bt709Linear`, `mk_bt709Linear` | verified (BT709 item 1.2; `testRec709OETFAndSixBandAnchors`) |
| BT.1886 EOTF | L = a·max(V + b, 0)^2.4, a = (LW^(1/γ) − LB^(1/γ))^γ, b = LB^(1/γ)/(LW^(1/γ) − LB^(1/γ)); V = (D − 64)/876. Output colour uses LB = 0, so L = V^2.4, mirrored below 0 (BT2408 §5.3) so extended range keeps sub-blacks | `ColorMath.bt1886EOTF/bt1886InverseEOTF` (`TransferFunctions.swift`), `MKMonitor.msl mk_toLinear/mk_fromLinear` | verified (`testBT1886EOTF`, BT1886 Annex 1: V = 0 → LB, V = 1 → LW; `OutputColorTests.testBT1886EOTFWithZeroBlackIsAPowerOf24`; GPU: `OutputColorGPUTests.testEveryEncodingMatchesTheCPUReference`) |
| Gamma 2.2 | L = V^2.2, mirrored below 0 | `ColorMath.gamma22EOTF/gamma22InverseEOTF`, `mk_toLinear/mk_fromLinear` | **convention** (the common display gamma; no standard defines it). Same tests |
| sRGB decode | V ≤ 0.04045 ? V/12.92 : ((V + 0.055)/1.055)^2.4; encode splits at 0.0031308 | `MKMonitor.msl mk_srgbDecode` (for `*_srgb` targets), `ColorMath.sRGBDecode/sRGBEncode`, `mk_toLinear/mk_fromLinear` (the `.sdr(.sRGB)` encoding) | verified (`testSRGBPiecewiseCurveIsContinuous`; GPU test). The branches meet within 1e−7 |
| PQ (ST 2084) | m1 = 2610/16384, m2 = 2523/4096·128, c1 = 3424/4096 = c3 − c2 + 1, c2 = 2413/4096·32, c3 = 2392/4096·32; E' = ((c1 + c2·Y^m1)/(1 + c3·Y^m1))^m2, Y = F/10000 | `ScopeTransfer.pqSignal/pqNits` (waveform nits graticule), `ColorMath.pqNits/pqSignal`, `mk_pqNits`, `mk_pqSignal` (output colour) | verified (BT2100 Table 4; `testPQMatchesST2084AndBT2408`, `OutputColorTests.testPQSignalInvertsTheEOTFAndHitsBT2408Levels`). 100 cd/m² → 0.508078 (10-bit narrow 509, full 519.8). 203 → 0.580689. 1000 → 0.751827. 10000 → 1. The shipped expressions are checked by `testShippedScopeTransfersAreST2084AndBT2100`. The EOTF clips its input to 0…1 on CPU and GPU, so legal super-whites stop at 10000 cd/m² (code 1019 used to decode to 24033) and the pole near E' = 1.99 produces no NaN (`ColorPipelineRegressionTests.testPQEOTFStaysInItsDomain`) |
| HLG OETF | E' = √(3E) for E ≤ 1/12, else a·ln(12E − b) + c. a = 0.17883277, b = 1 − 4a = 0.28466892, c = 0.5 − a·ln(4a) = 0.55991073 | `ScopeTransfer.hlgOETF/hlgInverseOETF` | verified (BT2100 Table 5, note 5c; `testHLGMatchesBT2100AndBT2408`, shipped text by `testShippedScopeTransfersAreST2084AndBT2100`). E' = 0.5 at E = 1/12. E = 1 gives 0.9999999951 because a is rounded |
| HLG system gamma | γ = 1.2 at LW = 1000. γ = 1.2 + 0.42·log10(LW/1000) for 400–2000 cd/m²; outside it the extended form 1.2·1.111^log2(LW/1000) (BT2100 note 5f) | `ScopeTransfer.hlgGamma`, `ColorMath.hlgSystemGamma` | verified (BT2100 note 5f; same tests; `OutputColorTests.testHLGOETFAndSystemGammaFollowBT2100`) |
| HLG OETF, EOTF and inverses (output colour) | scene light E = OETF⁻¹(E') (clipped to 0…1, so no super-white scene light), display F_D = LW·Y_S^(γ−1)·E per channel (the full OOTF, Y_S the luminance of E with the signal primaries' weights), inverse OOTF Y_S = (Y_D/LW)^(1/γ), E = F_D/(LW·Y_S^(γ−1)) (BT2100 Table 5) | `ColorMath.hlgOOTF/hlgInverseOOTF/hlgEOTF/hlgInverseEOTF`, `mk_toLinear/mk_fromLinear` | verified (`OutputColorTests.testHLGEOTFReproducesBT2408ReferenceLevels`, `testHLGInverseEOTFNeverExceedsFullScale`; GPU: `OutputColorGPUTests.testEveryEncodingMatchesTheCPUReference`). HLG is always encoded and decoded for the 1000 cd/m² reference display (BT2408 §6.2), so HLG → HLG is the identity and graphics white is 75 % HLG at any `hlgNominalPeak`; the nominal peak is only the PQ → HLG roll-off target, at most 1000 (`ColorPipelineRegressionTests.testHLGIsEncodedForItsReferenceDisplayAtEveryNominalPeak`) |
| HLG OOTF (achromatic, LB = 0) | F_D = LW·E^γ; inverse E = (F_D/LW)^(1/γ) | `ScopeTransfer.hlgNits/hlgSignal` | verified for achromatic signals (BT2100 Table 5 OOTF with Y_S = E; `testHLGMatchesBT2100AndBT2408` reproduces BT.2408's 38 % and 75 %; the shipped symbols: `ScopeGraticuleTests.testHLGAnchors`). The full OOTF scales RGB by Y_S^(γ−1); a graticule only needs the achromatic case |
| HDR reference levels | 18 % grey: 26 cd/m², 38 %PQ, 38 %HLG. Reference white: 203 cd/m², 58 %PQ, 75 %HLG (1000 cd/m² HLG display) | `WaveformScale.ticks` (203 tick), `MonitorOutputColor.referenceWhite` (graphics white, default 203) | verified (BT2408 Table 1). The test reproduces all four percentages from the PQ and HLG formulas; graphics white on the GPU: `OutputColorGPUTests.testGraphicsWhiteAndReferenceLevelsOnTheGPU` |
| Stops over grey on HDR | PQ (display light): log2(F_D/26); reference white +2.9649. HLG (scene light): log2(E/E_grey), E_grey = (26/1000)^(1/1.2) = 0.047843 (signal 0.3786, BT.2408's 38 %); reference white +2.4707 (= 2.9649/1.2; with the OOTF it is display light again, +2.9649) | `DisplayTransfer.exposureLinear`, `mk_exposureLinear` (HLG grey taken at exactly 38 %) | verified (`testStopsOnHDRSignalsUseTheirOwnTransfer`; GPU: `FalseColorTests.testCustomStopsLinearizeWithTheSignalsTransfer`) |

The task's anchor "HLG 0.5 at reference white" needs a qualification. In BT.2100 normalisation, E' = 0.5 at E = 1/12. That is ARIB STD-B67's old "reference white" (E = 1 on a 0…12 scale). The operational HDR Reference White is 75 % HLG (BT2408).

### 5.1 Display transforms (`MonitorColorPipeline`, `DisplayAssist`, `HDRToSDR`, `ToneMapEETF`, `BT2446MethodC`; `MKMonitor.msl mk_displayTransform`)

Applied after the monitor LUT, monitor-only. Any burn-in LUT, or a monitor LUT the surface shows, makes every transform unavailable (`.lutOnMonitorStage`): LUT output is Rec.709 display R'G'B' (`ColorPipelineRegressionTests.testALUTOnTheMonitorStageMakesEveryTransformUnavailable`). Tools keep measuring their own stage (`OutputColorGPUTests.testToolsMeasureTheirStageNotTheTransformedPicture`). GPU = CPU: `testLogToRec709MatchesTheCPUReference` (incl. `.fullRescaledToLegal` S-Log3 and LogC3 through v210, P210, 8-bit 4:2:2 and 16-bit biplanar), `testHDRToSDRMatchesTheCPUReference`, `testPassthroughFollowsTheHeadroomWithoutRebuilding`.

| Item | Value | Source | Status |
| --- | --- | --- | --- |
| Log → Rec.709 ("MonitorKit display assist v1") | per-channel log decode, camera gamut → Rec.709 in scene light (the matrices below), then the BT.709 OETF up to a 70 % knee at scene 0.4924 (+1.45 stops over grey), then the slope-matched shoulder V = Vk + (1 − Vk)(1 − (x/xk)^−q), q = 1.099·0.45·xk^0.45/(1 − Vk) | BT709 item 1.2 for the toe; the shoulder is a **convention** (value- and slope-continuous, monotonic, asymptotic to 100 %) | verified (`OutputColorTests.testDisplayAssistCurveIsMonotonicContinuousAndPlacesGrey`, `testLogToRec709PlacesEachCameraGreyAt40Point9`). Anchors: 18 % grey 40.9 % for S-Log3, LogC3 and LogC4; 90 % white card 85.4 %; +4 stops 96.4 %; +6 stops 99.3 % |
| PQ → SDR | BT2408 Annex 5 EETF (LB = Lmin = 0, knee KS = 1.5·maxLum − 0.5 clamped to ≥ 0, Hermite spline to maxLum) applied to maxRGB so hue is kept; source peak LW = `pqSourcePeak` (default 1000), target Lmax = `referenceWhite` (203); then BT.2020 → BT.709 in linear light, clipped (BT2407 §2), and the BT.1886 inverse EOTF | BT2408 Annex 5; BT2407 §2 | verified (`testEETFKneeAndRollOffAnchors` against an independent transcription of Steps 1–5, `testEETFWhereReferenceWhiteAndGreyLand`, `testPQToSDRIsMonotonicAndNeverLeavesTheSDRRange`). Grey (26 cd/m²) is below the knee and unchanged, 42.5 % SDR; reference white rolls off to 159.04 cd/m², 90.33 % SDR (recomputed in double precision). The maxRGB PQ signal is taken from the source codes (two fewer pow, mathematically the same). When Float(kneeStart) rounds to 1.0 (target a hair under the source peak) `mk_eetf` returns maxLum at and above the knee, matching the Double curve (no 0/0) |
| HLG → SDR | BT2446 Method C (§6.1): the HLG EOTF for the 1000 cd/m² display with γ = 1.2 (§6.1.1; BT2100 Table 5), eq. (5) on the luminance Y at constant chromaticity x, y (§6.1.3–6.1.5), BT.2020 → BT.709 in linear light clipped to 0…1 (BT2407 §2; §6.1: "one of the methods described in Report ITU-R BT.2407 may be used after HDR to SDR conversion"), and the BT.1886 inverse EOTF for the 100 cd/m² SDR display (§6.1.7) | BT2446 §6.1 eqs. (1)–(15); BT2407 §2 | verified (`OutputColorTests.testHLGToSDRIsMethodCWithItsAnchors`, `HDRDownConversionTests`; GPU: `OutputColorGPUTests.testHDRToSDRMatchesTheCPUReference`, `HDRDownConversionGPUTests`). Anchors (neutral, BT.2020): 38 % HLG (18 % grey, 26.24 cd/m²) → 21.99 cd/m², 53.2 % SDR; 50 % HLG (skin) → 70.0 %; 75 % HLG (HDR Reference White, 203.15 cd/m²) → 90.67 cd/m², 96.0 %; 100 % SDR at 332.6 cd/m² (eq. (5) solved for 100 cd/m²: Y = Y_ip·(e^((100 − k4)/k2) + k3) = 69.849 · 4.7614; ≈ 82.9 % HLG). Eq. (5) continues to 118.4 cd/m² at 1000 cd/m², which is 107.3 % SDR on the BT.1886 display ((118.38/100)^(1/2.4)); Table 1 separately lists Method C's output peak as 120 cd/m² (107.9 %) and its SDR signal range as 0–109 %. MonitorKit's SDR picture is defined up to 100 % (1.0 = graphics white, as for PQ → SDR, and the same on every output), so light above 332.6 cd/m² is SDR peak white, as on the 100 cd/m² display. The optional §6.1.8 (chroma correction above reference white, user parameter σ) is not applied. Label: "HLG → SDR · BT.2446 Method C". This is the only HLG → SDR path: it replaced (2026-10-23) MonitorKit's scene-light convention (75 % HLG scaled to 100 % SDR, the BT.709 OETF, a hard clip above reference white per BT2408 §7.6.4) |
| BT.2446 Method C parameters | k1 = 0.83802, k2 = 15.09968, k3 = 0.74204, k4 = 78.99439 (eq. 10); Y_HDR,ip = 58.535/k1 = 69.849 cd/m² (eq. 6); Y_SDR = k1·Y below Y_HDR,ip, k2·ln(Y/Y_HDR,ip − k3) + k4 from it (eq. 5), in cd/m²; α = 0 | BT2446 §6.1.4 | verified (`testMethodCParametersDeriveFromTheReportsConditions`: k1 = 100·0.7^2.4 / (1000·OETF⁻¹(0.5)^1.2) = 0.838017; with the inflection at 80 % SDR, 100·0.8^2.4 = 58.535 cd/m², eq. (7) gives k2, eq. (8) k4, and eq. (9) solved for k3 with Y_HLG,Ref = 1000·OETF⁻¹(0.75)^1.2 = 203.152 and Y_SDR,wp = 100·0.96^2.4 = 90.667 reproduce all four printed values to their last digit; `testMethodCCurveIsContinuousAndMonotonic`). Eq. (6) prints 58.5, but the printed k2–k4 come from the unrounded 58.535, and only with it is eq. (5) continuous (a 2e−5 cd/m² step and slope 0.838019 against k1; with 58.5 a 0.035 cd/m² step), so MonitorKit uses 58.535 (`BT2446MethodC.inflectionSDR`) |
| Method C as computed | eqs. (3)–(4) and (11)–(13) keep x, y and replace Y, so XYZ_SDR = XYZ_HDR·Y_SDR/Y_HDR; the crosstalk matrix C (eq. 2) and its inverse (eq. 14) then cancel round that scalar: RGB_SDR = C⁻¹·(Y_SDR/Y)·C·RGB = RGB·Y_SDR/Y, with Y the luminance of C·RGB. With the HLG EOTF, display light is L·Ys^(γ−1)·E and Y = L·Ys^γ (E scene light, Ys its luminance), so SDR light relative to 100 cd/m² is E·(k1·L/100)·Ys^(γ−1) on the linear segment and E·Y_SDR/(100·Ys) from the knee: one pow, one log2 and one division per pixel, no XYZ | algebra on BT2446 §6.1 | verified (`testMethodCThroughYxyIsALuminanceRatio`: Core's step-by-step `BT2446MethodC.toneMap`, through the crosstalk, XYZ, xy and back, equals the ratio form to 1e−9 for α = 0, 0.1 and 0.33 on BT.2020 and BT.709; `testMethodCXYZMatrixIsEquationThree` pins eqs. (3) and (13) to their printed four decimals; the shader's transform 3 against Core on the GPU) |
| Crosstalk α | 0: the crosstalk matrix is the identity | BT2446 §6.1.2 allows 0 ≤ α ≤ 0.33 and gives no value | **convention**. α only changes which luminance is tone mapped (C·RGB's, so saturated highlights are compressed more and clip less at the SDR peak: §6.1.2's aim of avoiding hue changes from clipping). With no published value to cite, MonitorKit takes 0, which keeps the Report's printed (achromatic) anchors exactly; a saturated colour brighter than the SDR peak in one channel is then clipped per channel by the BT2407 §2 step |
| Gamut step of both HDR → SDR transforms | BT2407 §2: the RP177 matrix from the source primaries to BT.709 in linear light, then each channel clipped to 0…1. Colours inside BT.709 are unchanged ("does not alter colours within the BT.709 gamut", §2.4); outside it, clipping can shift hue (§2.4) | BT2407 §2 eq. (1), §2.4 | verified (`OutputColorTests.testRec2020ToRec709IsBT2407`; GPU: `HDRDownConversionGPUTests`). Decision record (2026-10-23), both measured on the 4K v210 → 1080p pass whose test frame is far outside BT.709 everywhere: Annex 5 with its β = 0.2 soft clip cost +17 % of the pass and its 1 − f(r) cancels to 1.8 codes of float error at black; Annex 5's projection alone (A5.3–A5.4, β = 0; in-gamut colours exact) cost +8 to +9 % (on near-neutral colours too) and magnified the PQ chain's ~1e−5 float32 error into 1.1–1.8 codes in the near-zero channel of bright saturated colours. §2 is what Method C points to, costs nothing over the old path, and the GPU matches the reference to 0.002 of a 10-bit code for HLG and 0.12 for PQ, so it ships; a hue-preserving step stays open (`PROGRESS.md`) |
| HDR passthrough | the EETF from the 1000 cd/m² master (HLG decoded at 1000) to headroom × referenceWhite, into an extended-linear (or PQ) output; HLG → PQ rolls off to `hlgRolloffPeak` | BT2408 Annex 5 | verified (`OutputColorTests.testPassthroughRollsOffToTheHeadroom`; GPU as above). The headroom is a uniform: no pipeline rebuild when it changes |
| Identity conversions | an output whose transfer and primaries equal the picture's (no roll-off; extended linear excluded) converts nothing: `MonitorColorPipeline.convertsToTarget` is false and the native pipeline draws. PQ's inverse EOTF puts 0 cd/m² at 7.3e−7, so the shortcut is closer to the source than the round trip | — | verified (`ColorPipelineRegressionTests.testAConversionToThePicturesOwnEncodingIsTheIdentity`, `OutputColorTests.testSignalNativeConvertsNothing`) |
| S-Gamut3.Cine → Rec.709 (linear, D65) | [1.6269474 −0.5401385 −0.0868089; −0.1785155 1.4179409 −0.2394254; −0.0444361 −0.1959200 1.2403561] | RP177 from SONY-TS primaries | verified (`testCameraGamutToRec709MatricesDeriveFromPrimaries`; shipped: `OutputColorTests.testCameraGamutConversionsAreThePinnedRP177Matrices`). Rows sum to 1 |
| S-Gamut3 → Rec.709 | [1.8779151 −0.7941688 −0.0837464; −0.1768070 1.3509996 −0.1741926; −0.0262011 −0.1484223 1.1746234] | same | verified (same tests) |
| AWG3 → Rec.709 | [1.6175234 −0.5372866 −0.0802368; −0.0705727 1.3346131 −0.2640403; −0.0211017 −0.2269539 1.2480556] | same | verified (same tests) |
| AWG4 → Rec.709 | [1.8931234 −0.7808815 −0.1122419; −0.2057004 1.3402575 −0.1345571; −0.0127057 −0.1521849 1.1648906] | same | verified (same tests) |

**Why BT.2446 Method C for HLG, not Method A.** BT2446 offers three HDR → SDR methods. Method B maps a 291 cd/m² HDR signal (Table 1) and is not considered. Between A and C:
- Purpose (Table 1, "Intended primarily for"): A is for graded content (§4: movies, episodic, post-production) and aims for "a visual match with HDR input"; C is for live broadcast and aims for "a visual match with graded SDR content". MonitorKit monitors live camera signals, which is C's case. A is often called the usual broadcast conversion, but the Report itself assigns it to graded material.
- Input: C "assumes HLG input signals" (§6.1); A takes normalized display light at 1000 cd/m² from either system.
- Levels: C puts HDR Reference White (75 % HLG) at 96 % SDR "to ensure consistency with SDR original content" (§6, second bullet; BT2408 §7.7 asks for 90–95 %), and skin (50 % HLG) at 70 %. Method A, recomputed from Table 2 (ρ_HDR = 1 + 32·0.1^(1/2.4) = 13.26, ρ_SDR = 5.697), puts reference white (Y' = 0.203^(1/2.4) = 0.5146, Y'p = 0.7696, Y'c = 0.8284) at Y'_SDR = 68.7 % and 18 % grey (26 cd/m²) at 33.5 %. Next to the PQ → SDR transform (BT2408 Annex 5: white 90.33 %, grey 42.5 %) and to SDR cameras, A would show an HLG camera about 1.3 stops darker for the same scene, which misleads exposure on a monitor.
- Verifiability: C's printed parameters are reproduced from the conditions the Report states (above); A's knee coefficients are given without a derivation.
- Cost: C reduces to one luminance ratio per pixel (above); A needs luma, two logs, an exponential and the Y'CbCr colour correction of Table 3.
- What C leaves open: α (no value given; 0 here, a convention), the optional §6.1.8, and the BT.709 gamut step (any of BT2407's; §2 here). Table 1 gives its SDR signal range as 0–109 % (eq. (5) itself reaches 107.3 % at the 1000 cd/m² peak); MonitorKit's SDR picture keeps 0–100 % (above).

**PQ → SDR stays BT.2408 Annex 5.** BT2446 Method C is defined for HLG ("similar conversion might be possible for PQ input signals", §6.1, without parameters), and Method A would put PQ reference white at 68.7 % (above). BT2408 §5.2 prefers display-light mapping for PQ, and its Annex 5 EETF follows the content's mastering peak (`pqSourcePeak`), which neither BT2446 method does (both assume 1000 cd/m²). Both HDR → SDR transforms share the BT2407 §2 gamut step.

### 5.2 Output encoding and overlays (`MonitorColorPipeline.present/encode/overlayColor`, `mk_present`)

- Order after the monitor LUT: display transform → display adjustments (brightness, contrast, saturation, then white-point trim) → linearize with the picture's transfer → RP177 3×3 to the target primaries in linear light → optional roll-off → target encode (BT.1886, sRGB, gamma 2.2, extended linear, ST 2084 at `referenceWhite` per 1.0, or HLG for 1000 cd/m²). verified: `OutputColorGPUTests.testEveryEncodingMatchesTheCPUReference`, `OutputColorTests.testConversionsBetweenEncodingsRoundTripInLinearLight`, `testSDRWhiteLandsAtGraphicsWhiteInEveryEncoding`.
- Overlays are authored as Rec.709 SDR display values at graphics white and encoded per target on the CPU when settings change: 58.07 % PQ and 75 % HLG at 203 cd/m² (`testOverlayColoursPerEncoding`, `OutputColorGPUTests.testOverlaysOnHDRNativeLayersAreNotBlinding`). On a signal-native layer they stay as authored only for BT.1886 or sRGB on Rec.709 primaries (`ColorPipelineRegressionTests.testNativeOverlaysFollowTheLayersPrimariesAndTransfer`).
- A signal-native linear picture keeps values up to ±65504 (its layer is extended linear); every other picture written without conversion is clipped to 0…1 (`testNativeLinearPicturesKeepTheirRange`).
- Scopes (`MKScopes`): scope colours are authored as Rec.709 BT.1886 SDR. On any other overlay encoding each pixel is un-premultiplied, decoded with V^2.4, converted with the RP177 matrix to the target primaries, encoded (ST 2084 at referenceWhite; BT.2100 HLG inverse OOTF with γ from `ColorMath.hlgSystemGamma`, then the OETF; or linear, sRGB, gamma 2.2 or BT.1886) and premultiplied again. verified against `MonitorColorPipeline.overlayColor` to within 1e−3 on every pixel (`ScopeHDRTests`); graphics white 58.07 % PQ, 75 % HLG, 1.0 extended linear, never above it even with headroom (a convention for graphics, as the pass's overlays).

### 5.3 White-point trim (`WhitePointTrim`, `DisplayAdjustments.temperature/tint`)

The trimmed white is on the CIE daylight locus at the temperature (CIE15 §3.1 eqs 3.3 and 3.4, 4000–25000 K; the control allows 4000–10000 K, default 6504 K = D65 with c2 = 1.4388e−2), offset by tint along the locus normal in CIE 1960 uv (ANSI C78.377 Duv, positive is greener, ±0.02). Gains are RGB(trimmed white)/RGB(daylight at 6504 K) in the picture primaries, normalized so the largest is 1, and applied in linear display light after brightness, contrast and saturation (directly on the signal for BT.1886, gamma 2.2 and linear pictures, where a power law makes that exact). The locus at 6504 K is (0.31271, 0.32912), within 1e−4 of tabulated D65. verified: `ColorPipelineRegressionTests.testDaylightLocusAndTrimmedWhite`, `testWhiteTrimGainsMoveWhiteToTheTrimmedWhite`, `testWhiteTrimIsAGainInLinearLight`. It costs nothing when off.

### 5.4 Shader precision rule

Decode and classification use correctly rounded division (`mk_decodeCodes`, `mk_ycbcrToRGB`), so boundaries at integral codes are exact (940 is exactly 100 IRE); the W1 bit-for-bit tests enforce this. Output-colour transfer math (PQ EOTF and inverse, HLG inverse OETF and inverse OOTF, the EETF and tone maps, the log display assist, the sRGB decode in `mk_toLinear`) uses `fast::pow`, `fast::exp2`, `fast::log2`, `fast::divide` (at most 2.5 ulp) and reciprocals of constant divisors, bounded by the GPU-vs-CPU tolerance tests (≤ 1e−5). Integer remainders by a run-time divisor (zebra stripes) use an exact float-quotient remainder, `mk_modulo`, checked exactly against the CPU (`PerformanceRegressionTests`).

## 6. LUT interpolation (`LUTSampling.swift`, `MKLUT.msl`)

| Item | Value | Status |
| --- | --- | --- |
| Lattice addressing | p = clamp((rgb − min)·1/(max − min), 0, 1)·(n − 1); lo = floor(p), hi = min(lo + 1, n − 1), t = p − lo; .cube order has red fastest | verified (Adobe Cube LUT 1.0; `testTetrahedralAndTrilinearReproduceAffineLUTsExactly`, lattice points exact) |
| Tetrahedral | six tetrahedra selected by the order of t.x, t.y, t.z, with weights (1 − t₁, t₁ − t₂, t₂ − t₃, t₃) along the path c000 → … → c111 (Kasson, Nin & Plouffe, *Performing color space conversions with three-dimensional linear interpolation*, J. Electronic Imaging 4(3), 1995) | verified. CPU matches an independent sort-and-walk barycentric implementation to 2e−6 at sizes 2/17/33 (`testTetrahedralMatchesIndependentBarycentricReference`). Reproduces affine LUTs to 3e−6. Neutrals touch only c000 and c111 (`testTetrahedralKeepsNeutralsOnTheDiagonal`) |
| CPU/MSL tie-breaking | identical branch structure, so ties (t.x = t.y, …) resolve to the same tetrahedron | verified: `LUTTests.testTetrahedralAndTrilinearMatchTheCPUReferenceForEverySize` (≤ 2e−6 at 2/17/33/65, inputs include ties) |
| Trilinear | x, then y, then z lerps | verified (affine exactness; the same GPU test) |
| 1D shaper rows | a shaper's entries sit in rows of the texture width, which is at least 8 when there is a shaper; a lattice under 8³ sits in the corner of wider, edge-padded slices. `mk_shaperEntry(lut, i, n, w)` takes the row width; the hardware path normalizes by the texture size | verified: 65536-entry shapers on 2³ and 5³ cubes load and match the CPU reference (`LUTTests`) |
| Hardware | sample at (p + 0.5)/n with a linear filter and clamp-to-edge | verified: `LUTTests.testHardwareFilteringStaysWithinItsWeightPrecision` (a half-texel error would exceed its bound). Precision is the texture filter's (8 fractional bits on Apple GPUs), so it is excluded from the 1e−4 bar |

## 7. Scopes: vectorscope (`ScopeGraticule.swift`, `ScopeSettings.swift`)

Bars are R'G'B' ∈ {0, A} with A = 1 (100 %) or 0.75 (75 %). This follows ITU-R BT.2111 and SMPTE RP 219 (75 % bars, 100 % option). Cb = (B' − Y')/(2(1 − kb)) and Cr = (R' − Y')/(2(1 − kr)). Yellow and blue sit on the Cb rail at ±0.5·A, red and cyan on the Cr rail. Green and magenta are off-rail. Implemented by `VectorscopeTarget.bars(matrix:amplitude:)`; angles are counter-clockwise from +Cb (`VectorscopeTarget.angle`, in [0, 360); `ScopeGraticuleTests.testVectorscopeTargetAnglesFollowMATH`).

| BT.709 bar | 100 % Cb, Cr | 75 % Cb, Cr | 75 % 10-bit narrow codes | Angle |
| --- | --- | --- | --- | --- |
| Yellow | −0.500000, +0.045847 | −0.375000, +0.034385 | 176, 543 | 174.76° |
| Cyan | +0.114572, −0.500000 | +0.085929, −0.375000 | 589, 176 | 282.91° |
| Green | −0.385428, −0.454153 | −0.289071, −0.340615 | 253, 207 | 229.68° |
| Magenta | +0.385428, +0.454153 | +0.289071, +0.340615 | 771, 817 | 49.68° |
| Red | −0.114572, +0.500000 | −0.085929, +0.375000 | 435, 848 | 102.91° |
| Blue | +0.500000, −0.045847 | +0.375000, −0.034385 | 848, 481 | 354.76° |

BT.2020 targets for the 100 % bars:

| Bar | Cb | Cr |
| --- | --- | --- |
| Yellow | −0.5 | +0.040214 |
| Cyan | +0.139630 | −0.5 |
| Green | −0.360370 | −0.459786 |
| Magenta | +0.360370 | +0.459786 |
| Red | −0.139630 | +0.5 |
| Blue | +0.5 | −0.040214 |

The 75 % values are these × 0.75. Status: verified. `testColorBarVectorscopeTargets` derives them and checks that Core decodes them back to the bar R'G'B'; `testShippedScopeTransfersAreST2084AndBT2100` checks that `VectorscopeTarget.bars` uses the same Cb/Cr expressions; `ScopeAccumulationTests.testVectorscopeTargetsMatchColorBars` checks that GPU-decoded bars land on the targets.

| Item | Value | Where | Source | Status |
| --- | --- | --- | --- | --- |
| Skin-tone line | 123° counter-clockwise from +Cb | `ScopeSettings.skinToneAngle`, drawn by `ScopeGraticule` | NTSC-IQ: the I axis is at 123° in the **U/V** plane (`testSkinToneLineIsTheNTSCIAxis` derives it and recovers the FCC I row). The same hue direction is at 132.48° in a BT.601 Cb/Cr plot and 134.49° in BT.709 | **convention**: 123° is the angle broadcast vectorscopes carried over from U/V displays; MonitorKit plots Cb/Cr. The default is pinned by `testShippedScopeTransfersAreST2084AndBT2100` and `ScopeGraticuleTests.testSkinToneLineDefaultsToTheNTSCIAxis`; the doc comment now says "in the U/V plane" (9.9) |

### 7.1 Bins, graticule positions and statistics

| Item | Value | Status |
| --- | --- | --- |
| Vectorscope binning | bin = floor(c·z + side/2 + 0.5) per axis (c = Cb or Cr, z the zoom in bins per unit), so zero chroma is the centre of bin side/2; the renderer offsets half a texel to match | verified: neutral pixels land on the crosshair across bin sizes, zooms and odd/even viewports (`ScopeRenderTests.testNeutralFrameDrawsOnTheVectorscopeCentre`) |
| Waveform and histogram level ticks | drawn at the centre of the bin their exact level lands in (`ScopeLevelAxis.drawnFraction(ofLevel:bins:)`, mirroring `mk_levelBin`'s Float math), within half a bin of `ScopeLevelAxis.fraction` | verified (`ScopeGraticuleTests.testTicksSitOnTheBinTheirLevelLandsIn`, `ScopeBoundaryTests.testYCbCrParadeChromaTicksMatchTheBins`) |
| Minified axes | each plot pixel j gets the bins it overlaps, [floor(j·n/P), ceil((j+1)·n/P)), shifted half a bin for the vectorscope, max-reduced once per accumulation, display or plot-size change (`mk_scopeResolve`); each pixel then reads exactly one trace texel, matched in integers (`mk_ScopeDraw.pixels`). Parade panels split by min(floor((i + 0.5)·3/W), 2) in integers, each channel reduced over its own panel. No bin is ever lost; `MK_SCOPE_MAX_TAPS` is gone | verified (`ScopeRenderTests.testLoneBinSurvivesMinification`, `testParadeEdgeBinsSurviveMinification`, `testVectorscopeLoneBinsSurviveMinification`) |
| Graticule | rasterized as one instanced quad per shape (oriented around lines, a square around circles and boxes, expanded by half width + 1 px) into r8 with a max blend | **convention** (drawing); checked identical to the former compute rasterizer when it shipped; shapes and positions: `ScopeGraticuleTests` |
| SMPTE 240M colorimetry | kr, kg, kb = 0.212, 0.701, 0.087 (`ScopeColorimetry.smpte240m`) | verified by reading (SMPTE ST 240; `ScopeLifetimeTests.testSMPTE240MOverride`) |
| Statistics luma | Y' clip counts and luma min/max/average use the picture's stage-luma rule whatever `ScopeColorimetry` is: transport Y' where no LUT touched the stage, Rec.709 Y' (BT709 item 3.2) of a LUT result. Colorimetry drives only the drawn luma, the Y'CbCr parade and the vectorscope | verified (`ScopePictureAgreementTests.testLumaReadoutsFollowTheStageLumaWhateverTheColorimetry`) |
| Clip readouts | R', G', B' and Y' compared in percent with the picture's Float operations (`v·100 ≥ level` over, `≤` under; levels −20…120), so the counts equal the pixels `ClipIndicatorSettings` marks | verified: exact agreement for every channel, both sides, every stage with LUTs, 5 layout families (`ScopePictureAgreementTests.testClipReadoutsCountExactlyThePixelsTheClipIndicatorMarks`) |

## 8. Audio (`MonitorKitAudio`)

| Item | Value | Where | Source | Status |
| --- | --- | --- | --- | --- |
| K-weighting stage 1 (shelf), 48 kHz | b = 1.53512485958697, −2.69169618940638, 1.19839281085285; a1 = −1.69065929318241, a2 = 0.73248077421585 | `KWeighting.filters(sampleRate:)` | BS1770 Annex 1 Table 1 | verified (`testKWeightingPrototypeReproducesBS1770Tables`; shipped: `LoudnessTests.testKWeightingMatchesBS1770ReferenceCoefficientsAt48k`) |
| K-weighting stage 2 (RLB high-pass), 48 kHz | b = 1, −2, 1; a1 = −1.99004745483398, a2 = 0.99007225036621 | same | BS1770 Annex 1 Table 2 | verified (same tests) |
| Other sample rates | Analog prototype (shelf: f0 = 1681.974450955533 Hz, G = 3.999843853973347 dB, Q = 0.7071752369554196, Vb = Vh^0.4996667741545416; high-pass: f0 = 38.13547087602444 Hz, Q = 0.5003270373238773). At 48 kHz and above, bilinear transform; the high-pass numerator is scaled by a0(48 kHz)/a0(fs) so the passband gain is the 48 kHz filter's at every rate. Below 48 kHz the shelf is the matched design of the 48 kHz filter (M. Vicanek, *Matched Second Order Digital Filters*, 2016: same poles, magnitude equal at DC, f0 and Nyquist), within 0.04 dB at 8 kHz where bilinear warping errs by 0.28 dB | same | the parameters libebur128 uses (secondary) | verified: regenerates Tables 1/2 at 48 kHz to < 1e−13 (`testKWeightingPrototypeReproducesBS1770Tables`); `LoudnessTests.testKWeightingResponseIsRateIndependent`, `testLowSampleRatesReadTheSameLoudness`; shipped filter against a direct Double recursion: `ReferenceTests.testKWeightingMatchesDirectFilter` |
| Loudness | L = −0.691 + 10·log10 Σ Gᵢ·zᵢ; G = 1.0 for L/R/C, 1.41 for Ls/Rs; LFE excluded | `LoudnessEngine`, `LoudnessChannel.weight` | BS1770 Annex 1 eq. 2 and Table 3 | verified. The K-weighting gain at 997 Hz is +0.6910 dB, which −0.691 cancels (note 1; `testKWeightingPrototypeReproducesBS1770Tables`). Shipped: `LoudnessTests.testCase1And2SteadyToneReadsLevel`, `testCase6SurroundWeights`, `testLFEIsExcludedIn51` |
| Gating | 400 ms blocks, 75 % overlap; absolute gate −70 LKFS; relative gate −10 LU below the absolute-gated level | `LoudnessEngine` | BS1770 Annex 1 eqs 3–7 | verified: `LoudnessTests.testCases3To5Gating` (T3341 cases) |
| Momentary / short-term | 0.4 s / 3 s sliding rectangular windows, ungated; update ≥ 10 Hz | same | T3341 §2.2 | verified: `LoudnessTests.testCase9ShortTermIsConstant`, `testCase11ShortTermMaxima`, `testCase12MomentaryIsConstant`, `testCase14MomentaryMaxima` |
| Integrated | the BS1770 gating above | same | T3341 §2.3 | verified (gating tests above) |
| Loudness range | short-term (3 s) values at ≥ 10 Hz; absolute gate −70 LUFS; relative gate −20 LU; LRA = P95 − P10 | same | T3342 §3.1 and its Matlab reference | verified: `LoudnessTests.testTech3342LoudnessRange` |
| Targets | −23.0 LUFS; ±1.0 LU where not practical (live); ±0.2 LU measurement tolerance; maximum true peak −1 dBTP (±0.3 dB) | not in code (host policy) | R128 h), i), m) | verified by reading (transcription) |
| Max TP | R 128's "Max TP" is `AudioMeterSnapshot.programmeMaximumTruePeak`, over `programmeChannelMask`: every loudness-layout entry other than `.excluded`, LFE included, or every channel when loudness is off. `maximumTruePeak` is the all-channel maximum | `AudioMeterSnapshot` | R128, T3341 | verified (`ControlTests.testProgrammeMaximumTruePeakSkipsExcludedChannels`) |
| Pause and continue | `AudioMeter.pauseLoudness/resumeLoudness`, `LoudnessMeter.pauseMeasurement/resumeMeasurement`, effective at the next 5 or 10 ms tick boundary. Integrated, LRA and duration read as if the paused audio were cut out; momentary, short-term and their maxima keep running | `LoudnessEngine` | T3341 §2.2 | verified (`ControlTests.testPausedSegmentIsLeftOutOfIntegratedAndRange`, `testPauseTakesEffectOnTickBoundaries`) |
| Measurement reset | `resetLoudness()` / `LoudnessMeter.resetMeasurement()`: I, LRA, maxima and duration restart at the next tick boundary (the tick the reset falls in is left out like a paused one); M and S keep sliding; the maxima take only windows wholly after the reset. `reset()` clears the windows too. Reset requests are generation counters, so a reset shows in `snapshot()` at once and never reappears | `LoudnessEngine`, `ResetRequests` | T3341 | verified (`LoudnessTests.testResetMeasurementStartsOver`, `ControlTests.testLoudnessResetKeepsMomentaryAndShortTermRunning`, `RealtimeTests.testResetNeverReappearsWhileProcessRuns`) |
| Default loudness layout | 1, 2, 5 or 6 channels: mono, stereo, 5.0, 5.1 (BS1770 Table 3); any other count: channels 1–2 as stereo, the rest excluded (`programmePair`); presets include SMPTE 7.1 (L R C LFE Lss Rss Lrs Rrs, weights 1, 1, 1, 0, 1.41, 1.41, 1, 1). A layout that measures no channel is refused | `LoudnessChannel.standardLayout`, `validateLoudnessChannels` | BS1770 Table 3 (weights); the default pair is a **convention** | verified (`ControlTests.testDefaultLayoutsAndPresets`) |
| Publishing | at most once per `publishInterval` (default 5 ms); peak holds, maxima, clip counts and the PPM maximum lose nothing between publishes; `flush()` (or a zero-length `process`) publishes the tail and applies pending resets | `AudioMeter` | — | verified (`ControlTests.testPublishIntervalKeepsEveryPeak`) |
| CPU budget | well under 1 % of a core at 48 kHz (0.30 % in release for every meter on 16 channels); K-weighting and the true-peak FIR grow with fs, the PPM stops growing above about 192 kHz | — | — | `RealtimeTests` (the bound scales with fs/48 kHz) |
| True peak | 48-tap, 4-phase FIR (12 taps per phase), all four phases unmodified; oversampling 4× below 96 kHz and 2× (phases 0 and 2, half a sample apart) from 96 kHz up, never 1× (Tech 3341 cases 15–19 are defined at the meter's own rate), so the oversampled rate is at least 192 kHz from 48 kHz up (88.2 and 176.4 kHz both run at 352.8 kHz; BS1770 Annex 2: "at least 192 kHz"); below 48 kHz it stays under 192 kHz (176.4 kHz at 44.1 kHz, 128 kHz at 32 kHz) because Annex 2 defines no longer filter, so those readings are not formally dBTP; the sample peak is a floor. Phase p of sample n estimates time n − 5.875 + p/4. Optional 12.04 dB headroom attenuation for integer arithmetic (not needed in float); result in dBTP | `TruePeakFilter.phases`, `TruePeakFilter.oversampling(sampleRate:)` | BS1770 Annex 2 | verified: taps transcribed (`testTruePeakInterpolatorIsTheAnnex2Filter`) and the 48 shipped taps parsed from `Filters.swift` and compared exactly (`testShippedTruePeakTapsAreTheAnnex2Filter`); the shipped meter against a Double Annex 2 reference to 1e−4 dB (`ReferenceTests.testTruePeakMatchesAnnex2Reference`, `testTruePeakPhaseSweep`); behaviour: `PeakTests.testTruePeakTech3341Cases15To19AtEveryRate` (the meter's own fs/4, fs/6, fs/8 at 10 rates, 32–768 kHz), `…20To23`, `testTruePeakOversampledRateIsAtLeast192kHz`. Unmodified Annex 2 can read up to +0.204 dB on fs/4 at some start phases (its passband ripple); Tech 3341's +0.2 dB holds at its listed phases. Phase 3 is phase 0 reversed and phase 2 is phase 1 reversed. Per-phase DC gains are 1.00159 and 0.97302 (+0.014 dB and −0.237 dB): the published filter is an example, not unity per phase. Meters needing ≤ 0.2 dB under-read should use the Attachment's design guidance (or a longer filter) |

### 8.1 Level meters (IEC 60268-10/17/18)

The IEC parts are paywalled; the values below are from WIKI-PPM / WIKI-VU (secondary, citing the standards and EBU Tech 3205). The ballistics are realised by fitted filters (`AudioMeterConfiguration.swift`), so they are verified behaviourally by `BallisticsTests`, not by constants. The PPM charges from a grid of about 192 kHz: the true-peak phases below 176.4 kHz, the samples from 176.4 kHz, grouping round(fs/192 kHz) samples per step from about 288 kHz (so its work and time constants stop growing with the rate; checked against a direct reference at 384 and 768 kHz). `MeterScale` carries each meter's marks and zones (IEC 60268-18/-10/-17 marks from the published scale comparisons; the DIN semi-log breakpoints draw the face's shape and are not normative; zone colours are not standardized).

| Item | Source value | Implemented | Status |
| --- | --- | --- | --- |
| PPM Type I (DIN) integration | 5 ms burst of 5 kHz at reference reads −2 dB; tone bursts 10/5/3/0.4 ms → −1/−2/−4/−15 dB | `PPMBallistics.typeI`: two peak followers, 0.84 ms and 2.18 ms, fast weight 0.477 (fitted against the oversampled true-peak envelope) | **convention** (fitted). Verified behaviourally: `BallisticsTests.testPPMToneBursts` (tolerances ±0.5/±0.5/±1/±2 dB; the secondary gives no tolerances) |
| PPM Type I return | 20 dB in 1.7 ± 0.3 s | 20 dB in 1.5 s (`returnRate` 20/1.5 dB/s, attributed to DIN 45406 in code) | **convention** inside IEC's tolerance; DIN 45406 not read. `BallisticsTests.testPPMReturnTimes` |
| PPM Type IIa (BBC) / IIb (EBU) integration | 10 ms burst reads −2 dB; tone bursts 10/5/1.5/0.5 ms → −2/−4/−9/−17 dB | `PPMBallistics.typeII`: 1.13 ms and 5.03 ms, fast weight 0.505 (fitted, as Type I) | **convention** (fitted). `BallisticsTests.testPPMToneBursts` |
| PPM Type II return | 24 dB in 2.8 ± 0.3 s | 24/2.8 dB/s | verified (`BallisticsTests.testPPMReturnTimes`) |
| PPM scales | Type I: alignment −3 dBu reads −9 (PML 0); IIa: alignment reads 4, 4 dB per mark; IIb: alignment reads TEST, PML +9 | `PPMType.scaleReading` | verified (`BallisticsTests.testPPMScales`) |
| Digital peak return (IEC 60268-18) | 20 dB in 1.7 ± 0.3 s; integration < 5 ms | `peakDecayRate` default 20/1.7 dB/s | verified by reading (the default value). The decay mechanism is tested at another rate by `PeakTests.testPeakHoldAndDecay` |
| VU (IEC 60268-17) | 0 → 99 % of 0 VU in 300 ms (1 kHz step); overshoot 1–1.5 %; fall 300 ms | `VUBallistics`: 0.3 s, 1.25 %; second-order movement whose damping gives the overshoot and whose natural frequency reaches 0.99 at 0.3 s | verified: `BallisticsTests.testVUStepResponse` (overshoot within 1–1.5 %), `testVUBallisticsDesign` |
| Alignment levels | EBU R 68: −18 dBFS (0 dBu); SMPTE RP 155: −20 dBFS | `AlignmentLevel.ebu/.smpte`; VU and PPM default to EBU | verified (`BallisticsTests.testVUReferenceLevels`: −18 dBFS reads 0 VU on EBU, −20 dBFS on SMPTE) |

## 9. Discrepancies

Each entry gives the location, the value found, the correct value and the source. All of 9.1–9.9 were fixed on 2026-10-22 (the integration step of W1); each entry now names what shipped and the regression test. No test carries an `XCTExpectFailure` any more. The entries are kept as the record of what was wrong, since saved looks and earlier measurements were made with the old values.

1. **S-Gamut3 luminance weights** (**fixed**), `Sources/MonitorKitCore/Reference/ColorAnalysis.swift`, `ColorGamut.sGamut3`.
   - Was: (0.258685550974646, 0.724718154617408, 0.016596294407946).
   - Correct: (0.270979670813492, 0.786606411220905, −0.057586082034398).
   - Source: the Y row of the RP177 matrix from SONY-TS p.7 primaries. Sony's own matrix (SONY-XLSX) has 0.2709796708, 0.7866064112, −0.0575860820; the test accepts either (5e−11).
   - Impact: ARRI-style false colour, EL Zone and stops on S-Gamut3 sources (S-Gamut3.Cine is correct). The GPU gets the value from Core, so fixing Core fixes both.
   - Test: `testSGamut3LuminanceDerivesFromSonyPrimaries`.
   - Knock-on, updated with the fix: `ELZoneProfileTests.testSaturatedChannelsDecodeBeforeSourceGamutLuminance` (S-Gamut3 blue = 0.8 linear now has Y = −0.0461, black; red 0.65 reads −0.031 stops, same zone) and the comment in `ColorAnalysisTests.testSonyARRIStyleUsesDecodedSourceGamutLuminance` (Y = 0.2167837, code 419.49, still unclassified).
   - The retired `MonitorTools` package had the wrong constant; the app now uses MonitorKit's.
2. **Six-band comment** (**fixed**), `Sources/MonitorKitCore/FalseColorScales.swift`, doc comment on `SixBandFalseColor.bands`.
   - Was: "one stop over it is 59.4 IRE". Now 59.5 IRE (BT.709 OETF(0.36) = 0.594959).
   - The pink band [56.4, 62.4) still contains 59.5. If the band is meant to be centred ±3 IRE, the edges would be 56.5–62.5. That would be a versioned profile change, so it is optional.
3. **4:2:0 vertical chroma siting** (**fixed**: `ChromaVerticalSiting` center/top/bottom on `SignalDescription`, `DecodeReference.chromaTaps(vertical:)`, `mk_chromaCode` reading `FrameParameters.matrix.w`, `MonitorFrame.signal(of:)` mapping all six CoreVideo locations; tests `testChromaTapsMatchH273Siting` (types 0–5), `DecodeTests.testEveryVerticalChromaSitingOf420`, `testChromaLocationAttachmentsMapBothAxes`). H273 defines six positions; MonitorKit represented only types 0 and 1 (rows midway):

   | H.273 type | CoreVideo `kCVImageBufferChromaLocation_` | horizontal | vertical (luma rows) | chroma row coordinate for luma row y |
   | --- | --- | --- | --- | --- |
   | 0 | Left | x = 2i | 2j + 0.5 | (y − 0.5)/2 |
   | 1 | Center | 2i + 0.5 | 2j + 0.5 | (y − 0.5)/2 |
   | 2 | TopLeft | 2i | 2j | y/2 |
   | 3 | Top | 2i + 0.5 | 2j | y/2 |
   | 4 | BottomLeft | 2i | 2j + 1 | (y − 1)/2 |
   | 5 | Bottom | 2i + 0.5 | 2j + 1 | (y − 1)/2 |

   BT2100 Table 8 and BT2020 specify type 2, as HEVC HDR10 and Apple HDR captures label it. Types 2–5 were decoded half a chroma row off (colour fringing on horizontal edges). The locations that changed together:
   - `Sources/MonitorKitCore/Signal.swift`: the new `ChromaVerticalSiting` {center, top, bottom} on `SignalDescription` (saved descriptions without it decode as centred).
   - `Sources/MonitorKitCore/Reference/DecodeReference.swift` `chromaTaps(…, vertical:)`: cy = (y − 0.5 − offset)/2, the reference the GPU decode tests compare against.
   - `Sources/MonitorKit/Shaders/MKDecode.msl` `mk_chromaCode`: cy = (y − 0.5 − `matrix.w`)·0.5, with the offset in `FrameParameters.matrix.w`, so the choice is uniform and costs no branch.
   - `Sources/MonitorKit/MonitorFrame.swift` `signal(of:)`: all six CoreVideo chroma locations map to both axes (it used to fold TopLeft/BottomLeft into `.left` and Top/Bottom into `.center`).
   - Tests: `SyntheticFrame` and `DecodeTests` sweep every vertical siting; `testChromaTapsMatchH273Siting` covers types 0–5 from its `h273Siting` table.
4. **SMPTE 240M matrix** (**fixed**: `YCbCrMatrix.smpte240m`; `DecodeTests.testSMPTE240MMatrix`), `Sources/MonitorKit/MonitorFrame.swift` `signal(of:)`.
   - Was: kCVImageBufferYCbCrMatrix_SMPTE_240M_1995 → `.bt601` (0.299/0.587/0.114).
   - Correct: kr = 0.212, kg = 0.701, kb = 0.087 (SMPTE ST 240:1999).
5. **ARRI gamut placeholders** (**fixed**: `ColorGamut.arriWideGamut3/arriWideGamut4`, and the two ARRI profiles map to them), `Sources/MonitorKitCore/Signal.swift` `LogEncoding.init?(profileID:transport:)`: LogC3 was `.rec709`, LogC4 `.rec2020`.
   - `ColorGamut` has no ARRI Wide Gamut cases. `MonitorPass` sends `log.gamut.luminanceCoefficients` to `gamutWeights`, which `mk_stageFalseColor` uses for "stops" on LogC sources, so a LogC3 source gets Rec.709 weights for AWG3 and a LogC4 source gets Rec.2020 weights for AWG4.
   - Correct: add `arriWideGamut3` (0.291954, 0.823841, −0.115795; ARRI-C3 appendix) and `arriWideGamut4` (0.2545241764, 0.7814777327, −0.0360019091; ARRI-C4 eq. 5a) and map the ARRI profiles to them.
   - Literal ARRI false colour is unaffected: it uses eq. 1's Rec.709 weights on log RGB, by specification.
   - Tests: `testLogC3ProfileCarriesAWG3Luminance`, `testLogC4ProfileCarriesAWG4Luminance`, `testWideGamutLuminanceRowsDeriveFromARRIPrimaries`.
6. **Native log code, full container with rescaled transport, at 8/12/16 bits** (**fixed**), `Sources/MonitorKit/Shaders/MKDecode.msl` `mk_nativeLog` (`full && rescaled` branch) and `Sources/MonitorKitCore/Reference/DecodeReference.swift` `nativeLog` (`case (.full, .fullRescaledToLegal)`).
   - Was: (e·1023 − 64)/876 at every container depth.
   - Correct, with s = 2ⁿ⁻⁸ and M = 2ⁿ − 1 of the container, assuming the squeeze targeted the container's own legal range (16s…219s + 16s, as any n-bit legal encode does): t = (e·M − 16s)/(219s). Exact at 10 bits today; 8-bit legal white reads 1.00316 (0.3 %), 12-bit 0.08 %, 16-bit 0.10 % off. If a converter instead squeezed to 940·M/1023 (a 10-bit legal range scaled to the container), the current formula would be right; the assumption must be stated where the transport is documented.
   - Cases: bgra8 / `420YpCbCr8BiPlanarFullRange` / `64RGBALE` captures labelled `.fullRescaledToLegal`. The literal ARRI path's `(code − 64)/876·1023` rescale in `mk_logFalseColor` had the same 10-bit assumption in a full container; it now uses the same unsqueeze.
   - Shipped: `mk_unsqueezeLegal` takes M from `FrameParameters.levels.y` (a full container's maximum code; `MonitorFrame` now gives float RGB full 10-bit levels whatever its label), so `FrameParameters` keeps its layout; s = (M + 1)/256. At 10 bits the arithmetic is the old (e·1023 − 64)/876 operation for operation. `mk_logSignal` (LogC) and the literal ARRI rescale in `mk_logFalseColor` use it too. CPU: `DecodeReference.nativeLog(…, bitDepth:)`, `DecodeReference.unsqueezeLegal` and `LogCurve.signal(…, bitDepth:)`, defaulting to 10. The assumption is stated on `LogEncoding.transport`.
   - **Not a defect, do not change**: the legal + `.native` branch (e·876 + 64)/1023 is exact at every depth (section 1). An earlier version of this document proposed (e·219s + 16s)/M for it; that would have shifted every 8-bit legal S-Log3 source by +0.14 IRE at grey and +0.32 IRE at white.
   - Tests: `testNativeLogFullContainerRescaled8Bit/10Bit/12Bit/16Bit` (S-Log3 and LogC), `testNativeLogLegalAndFullNativeAreExactAtEveryDepth` (pins the exact branches), the 8/12/16-bit columns of `testShaderCurvesMatchTheCPUReferenceOnTheGPU`, and `FalseColorTests.testRescaledLogInFullContainersOfEveryDepth` (Sony Pattern 2 and literal ARRI on 8-bit biplanar and BGRA, 12- and 16-bit biplanar; it fails with the old formula).
7. **ARRI LogC read as code/1023 in a legal container** (**fixed** by the curve-aware `LogCurve.signal(expanded:range:transport:)` and its GPU mirror `mk_logSignal`, which return e for LogC and the native code for S-Log3; `DecodeReference.nativeLog` stays the S-Log3 mapping, so no `isCodeValued` flag was needed), `Sources/MonitorKitCore/Signal.swift` `LogEncoding.init?(profileID:transport:)` (default `.native`), `DecodeReference.nativeLog` and `MKDecode.msl mk_nativeLog` (legal, native branch).
   - Sony stores S-Log3 code values verbatim (SONY-TS Q4), so in a legal container the curve input is c/1023 = (e·876 + 64)/1023. ARRI carries LogC range-scaled (ARRI-FC §3.1; Table 9 grey 400 full, 406.5 legal = 64 + 876·0.391), so the curve input is e. The native mapping ignores the curve, and nothing in Sources sets another transport for ARRI profiles.
   - Was: LogC3 legal grey (406.52) → native 0.397382 → 0.19159 linear, **+0.090 stops**; LogC4 legal grey (307.88) → 0.23695, **+0.397 stops**; LogC3 E' = 0.6 → −0.32 stops, E' = 0.8 → −0.70 stops. Affects `mk_stageFalseColor`'s stops measure on LogC sources (the only consumer of `mk_logDecode` for ARRI curves). The literal ARRI path in `mk_logFalseColor` uses the stored code and is correct, so the two tools disagree on the same frame.
   - Correct: for ARRI curves t = e in a legal container with `.native`. In a full container, `.native` (extended/full link: t = e) and `.fullRescaledToLegal` (legal codes in a full container: t = (e·1023 − 64)/876) are already right for ARRI. So no single default transport fixes it: `.fullRescaledToLegal` would be right in a legal container but wrong for an ARRI full link, and it would also switch the literal path to the full table.
   - The curve is passed to the GPU in `PassParameters.luts.z`, which `mk_stageFalseColor` already had; the literal ARRI path keeps using the stored code.
   - Tests: `testLogC3ProfileDefaultTransportDecodesLegalGrey`, `testLogC4ProfileDefaultTransportDecodesLegalGrey` (legal and full grey at 8/10/12/16 bits), and the GPU sweep `FalseColorTests.testCustomStopsOnLogCFollowARRIsRangeConvention` (every code, both containers, both transports).
8. **Stops on non-BT.709 display sources** (**fixed**: `DisplayTransfer.exposureLinear` / `mk_exposureLinear` with the transfer in `PassParameters.luts.w`, and `requiresKnownTransfer` for unlabelled sources; section 4.6), `Sources/MonitorKit/Shaders/MKMonitor.msl` `mk_stageFalseColor` (non-log branch: `mk_bt709Linear` for every source) and `Sources/MonitorKit/MonitorPass.swift` `resolveFalseColor` (no gate on the display transfer). `MonitorFrame.signal(of:)` labels PQ and HLG buffers `.display(.pq/.hlg)`, and the plan includes PQ/HLG sources.
   - Was, read through the BT.709 inverse OETF: 38 % (BT.2408 grey in PQ and HLG) → −0.19 stops; 58 % (PQ reference white) → +0.93; 75 % (HLG reference white) → +1.65. sRGB and linear sources are also linearised with the wrong curve.
   - Correct: PQ: log2(PQ EOTF(E')/26) (display light; white +2.965). HLG: log2(E/E_grey) with the inverse OETF and E_grey = (26/1000)^(1/1.2) (scene light; white +2.471; use the OOTF at the declared peak if a display-referred measure is wanted, white +2.965). sRGB: the sRGB decode. Linear: identity. Or report `.unavailable` for transfers other than BT.709 until implemented.
   - Tests: `testStopsOnHDRSignalsUseTheirOwnTransfer` (the anchors, Core's measure for every transfer, and the old figures) and the GPU test `FalseColorTests.testCustomStopsLinearizeWithTheSignalsTransfer`.
9. **Skin-tone line angle in a Cb/Cr plot** (informational; the doc comment is **fixed**), `ScopeSettings.skinToneAngle = 123`.
   - 123° is the NTSC I axis in the U/V plane. MonitorKit's vectorscope plots Cb/Cr, where the I-axis hue lies at 132.48° (BT.601) and 134.49° (BT.709). Many component vectorscopes still draw 123°, so keeping it is a defensible convention; if the line is meant to mark the I-axis hue, the angle should follow the matrix. The doc comment now says "the NTSC I axis in the U/V plane" and gives the Cb/Cr angles; the 123° default is kept.
10. **Informational, not defects**:
    - `ColorMath.zebra(width:)` takes a full band width (±width/2). `ZebraSet.range` and the shader use ±range (half-width). They agree when width = 2·range.
    - LogC3 has a 5e−8 round-trip gap just above `cut` (section 2).
    - The BT.709 inverse has a 2.5e−4 step at 0.081, and `bt709Linear(0.081)` is 0.0179450, not 0.018 (4.6). Tests should probe either side of the split (0.0809, 0.0813), not 0.081 itself, unless the code adopts BT.2020's exact α/β.
    - The BS.1770 example FIR's per-phase DC gain is not unity (section 8).
    - PPM Type I returns 20 dB in 1.5 s, inside IEC 60268-10's 1.7 ± 0.3 s but not its nominal value (8.1).
    - BT2446 eq. (6) prints the inflection point as 58.5 cd/m², while eq. (10)'s parameters were derived with 100·0.8^2.4 = 58.535 (`testMethodCParametersDeriveFromTheReportsConditions`); MonitorKit uses 58.535 (5.1). Also noted while evaluating it (not shipped): BT2407 eq. (5-4) prints the soft clip's bracket without the square its quadratic Bézier (Fig. A5-4) needs to reach 1 at r = 1 + α.

## 10. Claims checked and refuted

- **Literal ARRI table in a full container** (an earlier 9.7). It said a full container or the rescaled transport classifies against the legal table with code·876/1023 + 64, and proposed `code = full ? A'_native·1023 : A'_native·876 + 64` with `A'_native = luma709(mk_nativeLog(e))`. The legal table is only selected for (legal, native) (`MonitorPass.resolveFalseColor`: full = full container or rescaled), and section 4.2 traces all four cells as correct. The proposed formula would break the one case it did not consider: in (legal, native), `mk_nativeLog(e)` = c/1023, so a stored 900 would classify as 834.7, about 65 codes off around the LogC3 red/orange edges (878/857).
- **Legal-container native log at 8/12/16 bits** (an earlier 9.6, see 9.6 above): exact at every depth.
- **`if (fy == 0) return top;` for co-sited 4:2:0** (a performance suggestion for 9.3). With top siting, fy alternates 0 and 0.5 by row, so every 2×2 fragment quad and every SIMD group spans both kinds of row and nothing retires early; the "saved" second row is the neighbouring row's own fetch and hits the cache. `mk_chromaCode` reads both horizontal taps unconditionally for the same reason (its comment), so the vertical choice should follow it.

## 11. What the guards prove

- `testShaderCurvesMatchTheCPUReferenceOnTheGPU` compiles `MKLUT.msl` + `MKDecode.msl` + `MKMonitor.msl` with the library's compile options and evaluates `mk_sLog3Decode`, `mk_logC3Decode`, `mk_logC4Decode`, `mk_logC3ReferenceCode`, `mk_bt709Linear`, `mk_srgbDecode`, `mk_luma709`, the four `mk_nativeLog` branches and the rescaled full branch at 8/12/16 bits at every 10-bit code against Core (relative error < 4e−6; one dispatch, read back in the test only). It skips without a Metal device.
- `testShaderCurveConstantsMatchSources` checks only that each constant still appears in the function (brace-matched, so one-line functions such as `mk_bt709Linear` and `mk_luma709` no longer capture their neighbours), plus the exact Sony IRE expression. Operator and branch changes are the GPU test's job.
- `testShippedTruePeakTapsAreTheAnnex2Filter` and `testShippedScopeTransfersAreST2084AndBT2100` read `Filters.swift`, `ScopeGraticule.swift` and `ScopeSettings.swift` as text, because this target cannot import MonitorKitAudio or MonitorKitScopes. They compare the 48 taps exactly and match the PQ/HLG/bar expressions with whitespace removed. Symbol-level checks: `ScopeGraticuleTests.testPQAnchors`, `testHLGAnchors` and `testSkinToneLineDefaultsToTheNTSCIAxis` on the shipped `ScopeTransfer`/`ScopeDisplay`; the shipped true-peak filter is checked behaviourally against the Annex 2 taps by `ReferenceTests.testTruePeakMatchesAnnex2Reference` (`TruePeakFilter` is internal and the audio tests import the module without `@testable`, so they also run in release builds).
- `ScopePictureAgreementTests.testPictureIREAndScopeClipCountsAgreeOnEveryLayoutAndStage` draws one frame of highlights straddling 940 through the picture pass (custom IRE false colour, which shares `mk_stageLuma` with the zebras) and through a scope, and checks that both count exactly the same pixels at or above 100 % at the source stage and after a burn-in LUT (the scope compares in percent with the picture's Float operations). `testClipReadoutsCountExactlyThePixelsTheClipIndicatorMarks` extends this to every channel and both sides against the clip indicator.
- The classification-table GPU tests (`FalseColorTests`) and the decode tests (`DecodeTests`) compare the GPU with the Core references; this document's tests tie those references to the sources.

## 12. Picture geometry (`MonitorLayout.swift`, `MonitorFrame.cleanAperture(of:)`)

| Item | Value | Where | Source | Status |
| --- | --- | --- | --- | --- |
| Clean aperture centre | pcX = horizOff + (W − 1)/2, pcY = vertOff + (H − 1)/2 in pixel coordinates, x to the right and **y down**, W × H the encoded frame | `MonitorFrame.cleanAperture(of:)` | ISOBMFF `clap` | verified (`PictureStageApertureTests.testWrapReadsTheCleanApertureAttachment`) |
| Clean aperture rectangle | left = (W − w)/2 + horizOff, **top = (H − h)/2 + vertOff**, size w × h (the `clap` width and height), clipped to the frame; nil when absent, not finite, or under a pixel on either axis once clipped | same; `MonitorFrameGeometry.shownRect` applies the same clip and fallback to a host-set `cleanAperture` | ISOBMFF `clap` (the aperture is centred on pc) | verified: the test writes CoreVideo's attachment (width 40, height 24, offsets +6, +5 in a 64 × 40 frame), reads `CVImageBufferGetCleanRect` (lower-left origin) and flips it, and gets x 18, y 13: a positive vertical offset moves the aperture **down**. A top of (H − h)/2 − vertOff is mirrored about the frame's centre. Clipping and the nonsense cases: same test and `LayoutTests.testUnusableAperturesShowTheWholeFrame` |
| Pixel aspect ratio | PAR = hSpacing / vSpacing; 1 when absent or not positive and finite; shown as square pixels (status `.unsupportedGeometry`) outside 1/16…16 | `MonitorFrame.pixelAspectRatio(of:)`, `MonitorFrameGeometry.pixelAspectRatioRange`, `effectivePixelAspectRatio` | ISOBMFF `pasp`; the 1/16…16 bound is MonitorTools' (**convention**) | verified (`PictureStageApertureTests.testUnusablePixelAspectRatioShowsSquarePixels`) |
| Display aspect ratio | DAR = w · PAR · d / h, with w × h the shown rectangle and d the anamorphic de-squeeze (1…4) | `MonitorFrameGeometry.displayAspectRatio(desqueeze:)` / `(for:)`, `MonitorLayout` | definition (a 1920 × 1080 aperture with square pixels and d = 2 is 3.556 : 1) | verified (`LayoutTests.testFrameGeometryDisplayAspect`, `testCleanApertureSetsTheAspectAndTheMap`) |
| Display → picture map | the fitted (or zoomed) image rectangle maps onto the aperture in frame pixels, flipped as asked; magnification's centre is normalized inside the aperture | `AxisMap.display(_:toPicture:flip:)`, `MonitorLayout` | — | verified (`LayoutTests.testCleanApertureWithMagnificationAndPixelExact`; GPU: `PictureStageApertureTests.testAsymmetricApertureShowsExactlyItsPixels`, `PortedCleanApertureTests.testAsymmetricApertureShowsTheTopLeftOriginedCleanRect`) |
| De-squeeze factors | 1, 1.3, 1.33, 1.5, 1.65, 1.66, 1.8, 2 (`ViewGeometry.standardDesqueezeFactors`); Sony's "1.6x" applies 1.65 | `ViewGeometry` | FX3 help guide (De-Squeeze Display, TP1001106329) and the Video Assist manual (1.33, 1.5, 1.66, 2) | verified by reading |

Edge sampling: a magnified picture's bicubic taps at the aperture edge read the frame's real pixels just outside the aperture rather than clamping at the aperture, since the aperture is a window onto the continuous image (**convention**). Focus analysis and scopes cover the whole frame; the focus footprint follows the aperture (`PictureStageApertureTests.testFocusFootprintFollowsTheAperture`).

## 13. Per-stage decode (`SignalDescription.outputReading`, `MonitorFrame.parameters(for:)`, `MKMonitor.msl mk_stages`)

A signal can carry two readings of the same codes. The source reading (`range`, `matrix`) is the camera's declared one: the source stage, log false colour and every classifier of the camera's own signal use it. The output reading (`outputReading`; nil means the source's) is the one the host's burn-in LUT and real output use: the Output and Monitor stages, with or without a LUT, and every tool, scope and focus analysis measuring them, decode with it. Typical cases: a camera declared full range on a legal-range link, or a SMPTE 240M source whose output path decodes BT.709.

| Item | Value | Where | Source | Status |
| --- | --- | --- | --- | --- |
| Each reading's decode | R'G'B'ₛ = M(kᵣ, k_b)ₛ · [(Y − bₛ)/sₛ, (Cb − c)/sᶜₛ, (Cr − c)/sᶜₛ] with the quantization levels b, s, c, sᶜ of the reading's range (section 1) and its matrix's kᵣ, k_b (BT.601/709/2020, SMPTE ST 240); RGB containers use the range alone, and the matrix for the transport luma | `MonitorFrame.parameters(reading:)`, `mk_decodeCodes` | BT709 item 3.4, BT2100 Table 9 (quantization); BT601 §2.5.1, BT709 item 3.2, BT2020 Table 4, SMPTE ST 240 (matrices) | verified (`OutputReadingTests.testEachPictureStageIsItsReadingsDecode`: every stage against `DecodeReference.rgb` in Double, v210, P010, UYVY and BGRA8, a 240M source among them) |
| Relation between the readings | R'G'B'ₒ = A·R'G'B'ₛ + t, an affine 3×4 (both decodes are affine in the codes and the source decode is invertible: A = Mₒ·Dₒ·Dₛ⁻¹·Mₛ⁻¹, t = Mₒ·Dₒ·(oₛ − oₒ), D the span scales, o the offsets) | — | — | **convention of implementation**: the shader does not apply the composed A and t to the source's Float R'G'B'. It decodes the filtered codes a second time with the output reading's own levels, matrix and correctly rounded reciprocals (`mk_decodeCodes`, the exact quotients of section 5.4). The composed form is exact only in real arithmetic: for full-declared v210 read legal, code 940 through the composition gives Y' = f(940/1023)·f(1023/876) + f(−64/876) = 0.99999994 in IEEE float32 (f the rounding to Float; the composed scale and offset, not the per-step (940/1023)·1023 − 64, which rounds back to exactly 876), so a 100 IRE zebra or clip indicator would miss the one code users test. The second decode gives exactly 1.0 (`OutputReadingTests.testZebrasAndClipIndicatorsAreExactAtEachStagesWhiteAndBlack`: codes 940…1023 and 0…64 marked on the Output stage, 1023 and 0 on the full-declared source, every picture stage) |
| Chroma centre | c = 2ⁿ⁻¹ in both ranges, so the centred chroma codes the filter sums (`mk_tapCodes`) serve both readings | `CodeRange.levels` | BT2100 Table 9 | verified by reading |
| Output-stage Y' | the output reading's transport Y' where no LUT touched the stage; Rec.709 Y' of the LUT result after one (`mk_stageLuma`, the scopes' `stageY`) | `mk_Stages.outputLuma` | section 7.1's one-convention rule | verified (`ScopeOutputReadingTests.testPictureAndScopeAgreeOnEachStagesReading`) |
| Stops on an untouched Output stage | the source's transfer (log curve or display transfer) applied to the output reading's values, its matrix weighting the display-transfer case | `mk_stageFalseColor` | section 4.6 | **convention**: the Output stage is what the output carries, read as the output is read, so its stops follow that reading (S-Log3 is code-valued, so its stops agree in both readings; LogC fills the container's range, so they differ) |
| Picture display transform | the log signal of the picture stage's reading (`mk_logSignalFast` with `mk_stageFrame(MK_PICTURE_STAGE)`) | `mk_displayTransform` | section 5.1 | verified (single-reading equivalence below) |
| False-colour grey under the display transform | an unbanded pixel's grey goes through the display transform with the reading it was decoded with: the measured stage's (`mk_stageFrame(stage)`) for the display-referred modes, the source's for the log modes; never the picture stage's | `mk_bands`, `mk_displayTransform(c, f, in)` | section 5.1 | verified (`OutputReadingTests.testFalseColorGreyUnderTheDisplayTransformKeepsItsReading`: S-Log3 declared full read legal and the reverse, `.logToRec709`, all-grey custom IRE, custom stops, Sony, ARRI-style and EL Zone; the image equals the measured stage's single reading on every picture stage) |
| Single-stage kernels | focus analysis and scopes measure one stage, so they bind that stage's whole `FrameParameters` (`MonitorFrame.parameters(for:)`) and run unchanged | `MonitorFeed.prepareAnalysis`, `ScopeAccumulator.begin` | — | verified: masks, bins and statistics equal those of a frame labelled with that stage's reading alone, bit for bit (`OutputReadingTests.testFocusAnalysisReadsItsStage`, `ScopeOutputReadingTests.testEveryScopeOfEveryStageReadsItsStage`, `testAFusedGroupReadsItsStage`) |
| Identity | no `outputReading`, or one equal to the source's: `PassParameters.outputReading.w` = 0, the output stage takes the source decode by assignment, every stage reads buffer 0's source `FrameParameters`; a specialized pipeline fixes this with bit 2 of function constant 1 (`MK_LUTS`), so it compiles no second decode (the all-tools pipeline reads the flag) | `mk_stages`, `mk_readsOutput`, `mk_outputFrame`, `MonitorPass.variant` | — | verified bit-identical: the W1 bit-exact suites and the Metal 4 / classic comparisons unchanged; `OutputReadingTests.testAReadingEqualToTheSourcesChangesNothing` |

Every tool on every stage (picture, both zebra sets, clip indicators, six-band, custom IRE and stops false colour, peaking), with and without both LUTs, draws exactly what a frame labelled with that stage's reading alone draws, and marks the same pixels whatever stage the picture shows (`OutputReadingTests.testEveryToolOnEveryStageMatchesItsStagesSingleReading`). Metal 4 is bit-identical to classic with a distinct output reading (`Metal4Tests` cases "declared full, output legal" and "240M, output BT.709").
