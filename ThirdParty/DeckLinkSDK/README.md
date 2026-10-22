# Blackmagic DeckLink SDK 16.0 (macOS interfaces)

`include/` is the unmodified `Mac/include` folder of the Blackmagic DeckLink SDK 16.0 (`BLACKMAGIC_DECKLINK_API_VERSION 0x10000000`). Each file keeps Blackmagic Design's license block, which permits redistribution with that notice intact; see the EULA at https://www.blackmagicdesign.com/EULA/DeckLinkSDK.

Only the interface headers and `DeckLinkAPIDispatch.cpp` are here. The SDK's samples and documentation are not. The Desktop Video driver installed on the Mac provides the implementation at run time.

Why 16.0: since SDK 14.3 the default input allocator captures into IOSurface-backed buffers, and `IDeckLinkMacVideoBuffer::CreateCVPixelBufferRef` returns them as CVPixelBuffers that Metal, VideoToolbox and Core Media I/O use without a copy. 16.0 adds `IDeckLinkStatistics` for device-level counters.

To update: replace `include/` with the new SDK's `Mac/include`, keep every license block, and update the version check in `scripts/fetch-decklink-sdk.sh`.
