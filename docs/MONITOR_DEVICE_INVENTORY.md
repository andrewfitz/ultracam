# Monitoring-assist inventory: Sony ILME-FX3 vs Blackmagic Video Assist 12G HDR

**Versions covered.**
- **FX3:** the current help guide, "ILME-FX3 Ver.2 or later" (helpguide 2210). It already covers firmware **Ver.7.00** (Aug 2025), which is the latest. Ver.4.x/5.x are no longer current.
  - Monitoring changes by version (verified): 3.00 added 1.3x/2.0x de-squeeze, the 16:9 aspect marker and Breathing Comp.; 4.00 added LUT import over C3 Portal; 5.00 added nothing for monitoring; 6.00 added shutter angle, the 709tone look and better 3D LUT quality; 7.00 added 1.5x/1.6x de-squeeze, Focus Magnifier during Bright Monitoring and Blackmagic RAW over HDMI.
- **Video Assist (VA):** Blackmagic Video Assist manual dated Nov 2025. The latest software is **3.23** (Aug 2026, stability fixes for 3G models only); the latest for 12G HDR is 3.22.
  - Judging by the one-line release summaries (the full release-note PDFs were not checked), nothing has changed in monitoring since 3.8 (Sep 2022, "upgraded RGB histogram"). 3.5 (Oct 2021) added LCD calibration and HDR format override.

**Key sources.**
- FX3 guide: https://helpguide.sony.net/ilc/2210/v1/en/index.html (PDF: …/print.pdf)
- VA manual: https://documents.blackmagicdesign.com/UserManuals/VideoAssistManual.pdf
- VA tech specs: https://www.blackmagicdesign.com/products/blackmagicvideoassist/techspecs/W-HYPERD-31
- VA release list: https://www.blackmagicdesign.com/api/support/us/downloads.json
- All TP…html page IDs cited below are under https://helpguide.sony.net/ilc/2210/v1/en/contents/
- FX3 Ver.6/7 changes: https://www.newsshooter.com/2024/09/12/sony-fx3-firmware-update-ver-6-00/ and https://www.newsshooter.com/2025/08/26/sony-fx3-ver-7-00-firmware-update/

---

## 1. Exposure

| Tool | FX3 | Video Assist 12G HDR |
|---|---|---|
| **Zebra** | On/Off. Zebra Level presets: **70 / 75 / 80 / 85 / 90 / 95 / 100 / 100+** (IRE). Two custom slots: **Custom1** is "correct exposure" by default (a standard value ± a range, so it marks a band) and **Custom2** is "overexposure" by default (a lower limit, so it marks everything at or above it). A secondary source calls these modes "Standard+Range" and "Lower Limit"; the help guide describes how they behave but does not name them. Defaults: Display Off, Level 70. **The exact custom ranges and step sizes are unverified** (the guide gives no numbers). A secondary source shows examples: 44 ±1 for mid-grey, **108+** for Rec709 clipping, **94+** for S-Log3 clipping. | On/Off with one threshold slider in %. Stripes cover everything **above** the set level. The manual's examples are 100%, 90% and 50%, and its screenshot shows 75%. **There is only one zebra, with no band mode.** The range and step size are **unverified**. |
| **False color** | Not available on the camera. | On/Off. **The legend is fixed and not configurable.** The chart is labelled at these points (left to right): **purple** = black detail loss; **blue** = near-black detail loss; **green** = 38.4% (18% middle grey); **pink** = 1 stop over middle grey (the manual also says "lighter skin tones"); **yellow** = 80% zebra / near-white clipping; **red** = 95% zebra / white clipping. Areas between bands show in greyscale. **The band edges in IRE are unverified** (the chart has labels only, no numbers). |
| **Histogram** | **Luminance only.** It is one of the DISP screen modes (Display All Info. / No Disp. Info. / Histogram / Level). No settings. | (a) "Display histogram" in the lower toolbar (Setup tab, default Off). (b) Histogram as a full scope. The manual text says "luminance," but the tech specs say **"RGB Histogram"** for 12G HDR and release 3.8 confirms the RGB upgrade. The toolbar screenshot shows overlaid R/G/B. |
| **Exposure readouts** | Shutter (speed or **angle**; angle range 5.6° to 64F for normal movies, 5.6°–360° for S&Q and at 119.88/100p), aperture, ISO. In Cine EI modes it shows EI / latitude / base ISO (e.g. "800EI/6.0E/L"). Metered Manual indicator. | None. The monitor has no camera metadata, except clips recorded in BRAW. |
| **Bright Monitoring** | Assignable key. Lengthens the LCD exposure so you can frame in the dark. Since Ver.7.00 it works with the focus magnifier in MF. | N/A |
| **EI preview** | Exposure Index (Cine EI): **±2 EV** around base ISO, i.e. **200–3200EI** at base ISO 800 and **3200–51200EI** at base ISO 12800. Shown on the monitor when Display LUT is On. | N/A |

Sources: …/contents/TP1000882797.html (zebra), TP1000885390.html (histogram), TP1000867629.html (DISP), TP1000888937.html (EI), TP1000868267.html (Bright Monitoring); https://www.pauljoy.com/2022/03/how-to-use-sony-exposure-tools-for-video/ (secondary, zebra examples); VA manual pp.13, 15–16, 27–28.

## 2. Color / scopes

| Tool | FX3 | VA 12G HDR |
|---|---|---|
| Waveform (luma) | **Not on camera.** | Yes, luma, with standard and HDR graticules (tech specs). For SDR, keep levels within 0–100%. |
| RGB parade | No | Yes, with SDR and HDR graticules. |
| YCbCr parade | No | **No** (not listed). |
| Vectorscope | No | Yes, with **100% color-bar targets**. No 75% option is documented. **Zoom 1x → 2x → 4x** by double-tap. The manual describes a skin-tone line "at ~10 o'clock" but **does not say it is drawn on the graticule (unverified).** |
| Scope display | n/a | Choose Video, Waveform, Parade, Vectorscope or Histogram (**one at a time**). Settings: **Scope Brightness** and **Background Opacity** (overlay on the video), or a **Preview** layout (full-screen scope with a draggable video picture-in-picture, top right by default). |
| HDR nit scale | n/a | The tech specs say "standard and HDR graticules" on waveform and parade. **The nit tick values are unverified.** |
| Monochrome / B&W | No | **Blue Only**: shows the blue channel as greyscale (for noise and focus). It is not a true luma B&W mode. |

Sources: VA manual pp.22–27, 34; techspecs URL above.

## 3. Focus

| Tool | FX3 | VA 12G HDR |
|---|---|---|
| **Peaking** | On/Off. **Level: High / Mid / Low.** **Color: Red / Yellow / Blue / White.** Defaults: Off, Mid, White. Works in MF/DMF, and with AF in movie mode. | "Focus assist" has two styles: **coloured edge lines** or **'Peak'** (the traditional sharpness peaking). **Sensitivity: Low / Medium / High.** The line colour can be changed, but **the colour list is not in the manual (unverified).** |
| **Magnify** | Focus Magnifier. Starting magnification in movie mode: **x1.0 / x4.0**. Stills: x1.0 / **x2.1** (full frame) or x1.0 / **x1.5** (APS-C/S35). Each press steps up the magnification. Can be panned (multi-selector, drag, or Delete to recentre). **Focus Magnif. Time: 2 s / 5 s / No Limit** (default No Limit). Auto Magnifier in MF defaults to On. **Markers are hidden while magnified.** | Double-tap gives **2x** zoom, with an inset showing the zoomed position. **Pinch for variable zoom** and drag to pan. Double-tap again to exit. Zoom does **not** affect the HDMI/SDI output. |
| **Focus Map** | **Not on the camera body.** It exists only in the Monitor & Control app (Ver.6.00 notes). | No |
| Focus area / face frames | Focus Area Color (default White). Face/Eye Frame Disp. (default Off). | No |

Sources: TP1000882771.html, TP1000844128.html, TP1000883904.html, TP1000876559.html; VA manual pp.13–14, 27.

## 4. Framing / composition

| Tool | FX3 | VA 12G HDR |
|---|---|---|
| **Aspect / frame guides** | Aspect Marker: Off, **9:16, 4:5, 1:1, 4:3, 13:9, 14:9, 15:9, 16:9 (Ver.3.00+), 17:9, 1.66:1, 1.85:1, 1.91:1, 2:1, 2.35:1, 2.39:1**. **There are no user or custom frame lines.** No opacity or colour settings are documented. | Frame Guides: **2.40:1, 2.39:1, 2.35:1, 2:1, 1.85:1, 14:9, 4:3**. **No 16:9, no vertical ratios, no custom ratio and no opacity setting are documented.** |
| **Safe area** | Safety Zone: **Off / 80% / 90%** | **None.** |
| **Grid** | Grid Line Display On/Off (default Off). Grid Line Type: **Rule of 3rds Grid / Square Grid / Diag. + Square Grid** (default thirds). | Grids: **Thirds, Crosshairs, Center Dot**. Thirds can combine with Crosshairs or with Center Dot. Crosshairs and Center Dot cannot be used together. |
| **Center marker** | Center Marker On/Off (one style) | Crosshairs or center dot (see Grid) |
| **Guide frame** | Guideframe On/Off (lines for checking level and perpendicular) | No |
| **Level** | "Level" DISP mode: pitch and roll indicator that turns green when level, accurate to about ±1°. | No |
| **Anamorphic de-squeeze** | De-Squeeze Display: **Off / 1.3x / 2.0x / 1.5x / 1.6x** (1.5x and 1.6x need Ver.7.00). Note: the guide says the **"1.6x" option applies a 1.65-fold correction.** Movie/S&Q only. It locks MF, Wide focus area and SteadyShot Off. It is not applied to RAW HDMI out, HDMI-only recording, or when Log Shooting is Off. | **Off / 1.33x / 1.5x / 1.66x / 2x**. **There is no 1.8x.** |
| **Flip / rotate** | Monitor Flip Direction: **Auto / Horizontal Flip (mirror) / 180 Degree Flip / No Flip**. A key cycles through H → 180 → None. | LCD Screen Rotation: **Auto / None (locked) / 180°**. **There is no mirror option.** |

Sources: TP1000868276.html (markers), TP1000885416.html (grid), TP1001106329.html (de-squeeze), TP1000888923.html (flip); VA manual pp.14–15, 34.

## 5. LUT / color pipeline

| Item | FX3 | VA 12G HDR |
|---|---|---|
| **Display LUT** | Display LUT **On/Off** (default On), with an assignable "Display LUT Switch" key. Select LUT has 3 presets: **S-Log3, s709, 709(800%)** (default s709), plus **User1–User16**. | "Display 3D LUT" On/Off. You choose one LUT from the LUTs tab. |
| **User LUT import** | **.cube, 17- and 33-point only.** 16 slots. Location: SD card `/PRIVATE/SONY/PRO/LUT`, CFexpress A `/SONY/PRO/LUT`. File name up to 63 characters. Per slot you set Input (gamut) and **AE Level Offset 0 to +2 EV in 1/3 steps**. C3 Portal import needs Ver.4.00+. | .cube import from SD or drive. **Supported point sizes and slot count are unverified.** |
| **LUT baked into recording** | **PPLUT1–PPLUT4**: a user LUT used as the "Basic Look" is **recorded**. Embed LUT File On/Off writes metadata (not available on SD/SDHC). | **Never baked.** The manual says the LUT is "only used on the display." Apply LUT in File (BRAW only) embeds it as metadata. |
| **Gamma Display Assist** | On/Off (default Off). Type: **Auto / S-Log3→709(800%) / HLG(BT.2020) / HLG(709)**. Auto picks the type from the picture profile gamma. **Locked Off when Log Shooting is not Off** (use Display LUT then). | n/a (use a LUT) |
| **Log Shooting mode** | **Off / Flexible ISO / Cine EI Quick / Cine EI**, plus a Color Gamut setting. | n/a |
| **LUT on HDMI/SDI out** | **Unverified.** Not stated in any page fetched. Related verified fact: HDMI output **drops to 1080** when Log Shooting is on or PPLUT1–4 is selected, unless HDMI-only or RAW output. | **Not stated in the manual (unverified).** |
| **HDR handling** | HLG recording (PP10 / HLG1–3). | Detects HDR metadata automatically and shows "HDR" next to the timecode. **HDR Format Override** (separate settings for playback and record): **Auto, Rec.709, Rec.2020 SDR, HLG, ST2084 (300 / 500 / 800 / 1000 / 2000 / 4000 nits)**. HDR flags are passed through on SDI and HDMI out. Tech specs: HDR10 and HLG. Panel: 2500 nits, P3, Rec.601/709/2020. |

Sources: TP1000888936.html, TP1000888941.html, TP1000888940.html, TP1000888942.html, TP1000876505.html, TP1000885443.html, TP1000885432.html; VA manual pp.22, 33, 36–38.

## 6. Audio

| Item | FX3 | VA 12G HDR |
|---|---|---|
| Meters | On-screen audio level meter. Shows **4 channels during 4ch recording** (with the XLR handle). Showing 2 channels otherwise is inferred, not stated. **The scale and markings are unverified** (not in the guide). The meter is hidden when Audio Recording is Off or in No Disp. Info. mode. | **Up to 4 meters in the lower toolbar.** You choose which pair shows in the lower two ("Monitor channels"). Meter type: **VU (-18 dBFS), VU (-20 dBFS), PPM (-18 dBFS), PPM (-20 dBFS)**. PPM has peak hold with slow fall-back. **The full scale is unverified** (the screenshot appears to read roughly -60 to 0). Zones are green / yellow (target peaks) / red (clipping). Up to **16 channels** can be recorded (2–16); the manual says the meters can show up to 16 channels, against 4 in the toolbar. |
| Monitoring | 4ch Audio Monitoring: **CH1/CH2, CH3/CH4, CH1+3/CH2+4, CH1/CH1, CH2/CH2**. HDMI 4ch output: CH1/CH2 or CH3/CH4. | Speaker and headphone level sliders. On 7" models: XLR level, line/mic, pad and phantom power. |

Sources: …/print.pdf ("Shoe Audio Set." hint; Audio Rec Level), TP1000885437.html, TP1000885432.html; VA manual pp.31–34.

## 7. Status / metadata

| Item | FX3 | VA 12G HDR |
|---|---|---|
| Timecode | TC/UB Disp. Setting: **Duration / TC / U-Bit** (default TC). Shows EXT-LK when locked externally. | Large timecode readout in the toolbar, red while recording. Timecode output: Timeline or Clip. |
| Recording tally | **Emphasized REC Display** (red frame on the monitor, default On). It also appears on HDMI if HDMI Info. Display is On. | Red tally LED on top (brightness Low/Med/High). Red timecode and red media bar while recording. |
| Other | Battery, media, remaining time, codec/resolution, frame rate, LUT name, Gamma Assist icon, WB, network icons, overheat warning. | Codec, standard, source, dual battery (red below 25%), media remaining (red under 5 min, flashing under 3 min), dropped-frame "!" alert. |

Sources: TP1000876457.html, TP1000885444.html, TP1000888863.html; VA manual pp.21–22, 28–30, 35.

## 8. Display adjustments

| Item | FX3 | VA 12G HDR |
|---|---|---|
| Brightness | Monitor Brightness: **Manual (-2 to +2)** or **Sunny Weather** | Brightness slider in % (up to 2500 nits). **Auto Dim** above about 46 °C. |
| Contrast / saturation | No | **Contrast** and **Saturation** sliders. These affect the LCD only. |
| Quality | Display Quality: **High / Standard** (default Standard; can lock to Standard when hot) | n/a |
| Calibration | No | LCD white balance calibration: **LCD temperature** and **LCD tint**, with reset and restore. |

Sources: TP1000868292.html, TP1000843982.html; VA manual pp.16, 36.

## 9. Output routing and compositing

**FX3**
- **Monitor only:** markers ("You cannot output the markers"), zebra and peaking ("not displayed on devices connected via HDMI"), and Gamma Display Assist (not applied on external displays).
- **HDMI Info. Display On:** shooting info goes to HDMI and the camera LCD goes blank. **Off:** HDMI is clean and the LCD keeps the image plus info. Default On.
- HDMI Info. Display is forced Off for HDMI-only recording and for RAW output.
- The Emphasized REC frame can go to HDMI.
- **Running together:** several markers can be shown at once (verified). Markers are hidden during Focus Magnifier (verified). Gamma Display Assist is locked Off in Log modes (verified). Histogram and Level are alternative DISP screens, so they cannot be shown together. Zebra, peaking and grid have separate menu switches, so they can probably be combined, but this is inferred, not stated.

**Video Assist**
- All overlays are gathered in the "monitor overlay" menu. **Clean Feed turns every overlay off with one switch.**
- **Running together:** zebra, focus assist, frame guides, grid, false color, Display 3D LUT and Blue Only each have their own switch in the Monitor tab (screenshot). The manual does not say how they render together. Only one scope is shown at a time.
- **On the LCD only (documented):** zoom, and brightness/contrast/saturation.
- **Output:** the manual does **not** say whether overlays or LUTs go to HDMI/SDI out. **Unverified; do not assume a clean or overlaid loop-out.**
- **Recording:** recordings are always clean.

Sources: TP1000843990.html, TP1000868276.html, TP1000876505.html; VA manual pp.12–13, 16, 27, 37.

---

**Unverified items, collected:** FX3 custom zebra ranges, steps and mode labels; FX3 audio meter scale; FX3 LUT on HDMI. VA zebra range and step; VA peaking colour list; VA false color band edges in IRE; VA .cube point sizes and LUT slot count; VA HDR graticule nit values; VA skin-tone line drawn on the graticule; VA overlay/LUT on loop-out.
