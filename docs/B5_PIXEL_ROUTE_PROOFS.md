# B5 pixel route evidence

This manifest describes the `PixelFormatTable` route qualifications. Registration
allows a format declaration; it does not authorize capture. Capture admission requires
all six GPU routes and explicit end-to-end writer/capture qualification. Recording-source and LUT admission require their respective
proven GPU routes and recheck the requested stage for every frame. The approved 2vuy, yuvs, 420v, 420f, BGRA, r210 and R12L entries now have
the complete capture set. UYVA, P216, I420 and PA16 are also qualified after
the actual writer checks below. RGBA remains partial.

“Native CV” means an IOSurface-backed Core Video source fixture, not a synthetic
float texture. Primitive raw-buffer tests do not prove an app consumer route.

| Formats | Stage | Test evidence | Storage / qualification |
|---|---|---|---|
| 2vuy, yuvs, 420v, 420f, BGRA, r210, R12L | extension feed output | `SourceFormatRouteChecks.testEveryNewSourceReachesAnExactPublishedProcessedCameraFormat` | Actual typed nonlinear LUT GPU processing, 14 submissions (seven sources × 720/1080), expected grey code 71, `CameraSink.requestedFormat` matches exact published catalog; no physical external client claim |
| r210, R12L and registered raw formats | monitor | `Packages/MonitorKit/Tests/MonitorKitTests/RawCVFrameDecoderTests.swift:testRegisteredCaptureCVEnvelopesReachMonitorOutputOnMetal4` | Actual CV envelopes mapped and rendered through MonitorPass; all six newly registered raw cases pass |
| 2vuy, yuvs | input | `Packed422GPUChecks` | Raw-buffer Metal 4 decoder, both byte orders; not a full capture route |
| 2vuy, yuvs | LUT | `Packed422LUTChecks.testBothPackedOrdersRunProductionFullAndResizeKernels` | Native CV, full and resize, NV12 and 422 output |
| 2vuy, yuvs | Program | `ProgramScalingGPUChecks.testPackedSourcesExecuteThroughProgramOutput` | Native CV 128×64, actual Program GPU pixels |
| 420v, 420f, P216 | input | `PlanarGPUChecks.testGPUDecodesEveryFormatAtNativePrecisionWithRangeHeadroom`, `testGPUChromaReconstructionHonorsHorizontalAndVerticalSiting` | Native GPU plane textures; exact range/headroom and siting, not every allocator |
| 420v, 420f, P216 | LUT | `LUTPlanarGPUChecks.testPlanarFormatsExecuteThroughNonlinearLUTWithNativeRanges` | IOSurface-backed plane fixtures, nonlinear LUT; P216 requires custom native CV storage |
| 420f | Program | `ProgramScalingGPUChecks.testFullRange420SourceIsConvertedToVideoBlack` | Native CV, full-range zero becomes video-range 16 |
| 420v | Program | `ProgramScalingGPUChecks.testPortraitFitsWithBlackPillarboxAndCropFills` | Native CV 32×64; fit border Y16/centre Y100, crop border and centre Y100 |
| BGRA, RGBA, r210, R12L | input | `RGBGPUDecoderChecks.testGPUDecodesPackingAndPaddedOddRows` | Raw-buffer GPU decoder, padded odd rows; RGBA app route unqualified |
| BGRA, r210, R12L | LUT | `LUTDynamicSizeChecks.testRGBSourcesExecuteThroughLUTOutput` | Native CV 128×64, actual output pixels |
| BGRA | Program | `ProgramScalingGPUChecks.testRGBSourceAndProgramPQTargetConvertPixelsOnGPU` | Native CV, colour conversion to PQ |
| r210, R12L | Program | `ProgramScalingGPUChecks.testPackedSourcesExecuteThroughProgramOutput` | Native CV 128×64, actual output pixels |
| r210 | recording | `RecordingRGBEncoderConformanceChecks.testR210VideoRangeLegalBlackWhiteAndClippedHeadroomRoundTrip`; `RecordingRGBPixelConverterChecks.testPackedR210PreservesAllCodesIncludingVideoHeadroom` | Native source GPU codes plus actual encode/decode legal-range check |
| R12L | recording preparation | `RecordingRGBPixelConverterChecks.testPackedR12LOddRowsPreserveAllTwelveBitCodes` | Native CV source repack, odd rows; writer/encoder qualification separate |
| BGRA | recording | `RecordingRGBEncoderConformanceChecks.testBGRAFullRangeRepackAndActualProRes4444ColorRoundTrip` | Native BGRA source, GPU repack, actual ProRes 4444 encode/decode colour check |
| 2vuy, yuvs, UYVA | recording | `Packed422RecordingChecks.testNativePackedOrdersAndRawUYVARepackEveryEightBitCodeExactly` | Native packed/alpha source, GPU x422 repack all 8-bit codes; alpha retained/validated but ignored in picture |
| 420v | recording | `PlanarRecordingConverterChecks.testNative420VideoIsAcceptedByHEVCMainWithoutConversion` | Actual VideoToolbox HEVC Main native-input acceptance |
| 420f | recording | `PlanarRecordingConverterChecks.testFullRange420GPUMapsBlackWhiteAndNeutralIntoVideoRange` | Native GPU range conversion to 420v and actual HEVC Main encode |
| P216 | recording | `PlanarRecordingConverterChecks.testP216GPUQuantizesAllNativeLowBitsAndEncodersAcceptX422` | GPU nearest 16→10 x422, actual ProRes HQ and HEVC 422 encoder samples; no Main10 claim |
| UYVA, I420, PA16 | LUT | `LUTUYVAChecks.testNativeUYVAExecutesNonlinearLUTAndResizeIgnoringValidatedAlpha` and `LUTNDIPlanarChecks.testCustomI420AndPA16ExecuteNonlinearLUTAtNativeAndResizedDimensions` (B4 focused 54-test GPU run) | Actual registered native CV storage, alpha retained/ignored, nonlinear LUT output pixels; no remaining-consumer inference |
| UYVA | actual writer qualification | `RecordingPackedWriterChecks.testActualWriterEncodesRawUYVAAndRetainsSourceDescription` | Actual MOV, decoded pixel blocks, colour and immutable original source identity; focused packed writer 4-test run |
| I420 | actual writer qualification | `RecordingNDIWriterChecks.testActualI420WriterMOVHasExpectedPixelsColourAndOriginalSourceIdentity` | Actual MOV, five gray blocks, canonical encoder pixels, colour tags, zero CPU conversions, original source provenance |
| PA16 | actual writer qualification | `RecordingNDIWriterChecks.testActualPA16WriterMOVIgnoresAlphaAndKeepsOriginalSourceIdentity` | Actual MOV, validated retained alpha ignored in picture, five gray blocks, zero CPU conversions, original source provenance |
| P216 | actual writer qualification | `RecordingNDIWriterChecks.testActualP216WriterMOVHasExpectedQuantizedPixelsAndSourceIdentity` | Actual MOV, native 16→10 quantized gray blocks, colour tags, zero CPU conversions, source provenance |
| UYVA, P216, I420, PA16 | Program | `ProgramScalingGPUChecks.testNDIPlanarAndAlphaSourcesExecuteThroughProgramOutput` | Native registered CV → production Program GPU → Y126±1, unchanged source FourCC; 48 focused route/GPU/policy tests passed |
| I420 | recording preparation | `PlanarRecordingConverterChecks.testI420SeparateUVPlanesBecomeNative420vAndEncodeWithoutRelabeling` | Separate native U/V planes → GPU 420v → actual HEVC Main packet; writer integration qualification separate |
| PA16 | recording preparation | `PlanarRecordingConverterChecks.testPA16AlphaIsRetainedAndIgnoredWhileNative16VideoQuantizesToX422` | Retained validated alpha, native 16-bit → GPU x422 → actual ProRes HQ packet; writer integration qualification separate |
| UYVA, P216, I420, PA16 | monitor | `RawCVFrameDecoderTests.testRegisteredCaptureCVEnvelopesReachMonitorOutputOnMetal4`, `testBackToBackGPUCopiesAndMonitorPassesSeeEachFramesColour`, `testCaptureStorageOwnerSurvivesFrameDropUntilGPUFeedback` | Actual registered CV host adapter and MonitorPass GPU output; barrier/lifetime tests cover delayed completion |
| UYVA, P216, I420, PA16 | extension feed output | `SourceFormatRouteChecks.testEveryNewSourceReachesAnExactPublishedProcessedCameraFormat` | Expanded 22 actual typed nonlinear GPU submissions across eleven formats × 720/1080; exact output code and published catalog match, no external client claim |
| I420, PA16 | input | `NDIPlanarGPUChecks.testI420SeparateChromaPlanesAndPA16NativePrecisionIgnoreAlpha` | Standalone Metal 4 decoder; separate I420 chroma planes and PA16 alpha present but ignored in v1 processing |
| I420, PA16, P216, UYVA | ingest storage | `CPUMemoryGPUIngestChecks.testNDIPlanarStorageAndAlphaArePreservedOnGPU` | Actual plane storage preserved through GPU ingest, including alpha; does not prove LUT/Program/recording |
| UYVA | input | `Packed422GPUChecks` | Standalone decoder, UYVY plus alpha planes |
| 2vuy, yuvs, 420v, 420f, BGRA | monitor | `Packages/MonitorKit/Tests/MonitorKitTests/RawFrameDecoderTests.swift:testExistingCVFormatsMapIntoMonitorTexturesAndDecodeOnGPU` | Native CV texture mapping and GPU decode: uyvy8/yuyv8/nv12 legal/full/bgra8 full; other range/storage variants unqualified |

UYVA, P216, I420 and PA16 now have all consumer route proofs and actual-writer
qualification; `captureQualified` is true. RGBA retains missing consumer routes
and remains refused for capture. The approved extension route processes source pixels
into a published output contract; it does not add raw source layouts to the catalog. The extension's output-layout standby
proof is separate from raw input conversion. Where a row proves preparation only, hardware encoder acceptance, decoded range,
and file metadata remain separately qualified. I420, PA16, P216 and UYVA actual MOV writer tests now validate canonical
encoder pixels, colour tags, original source provenance and zero CPU conversions. No test here
authorizes CPU fallback or changing the physical source declaration.

The legacy v210 descriptor and revision remain unchanged. Its existing shipping
route set is retained; `SourceFormatContractChecks.testExistingCanonicalSignatureRemainsStable`
pins its canonical format identity.
