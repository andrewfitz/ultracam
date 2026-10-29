#!/usr/bin/env python3
"""Inventory CPU pixel access and fail on unclassified review triggers.

This lexical check cannot prove data flow or the recorder's internal
VideoToolbox conversions. It complements the required encoder-format test.
Classifications match path + enclosing symbol + exact normalized call and
maximum static occurrence count. No production file/type is exempt. A future
CPUCompatibilityConverter needs separately reviewed call sites and runtime
opt-in/counting tests; its name alone grants no exemption.
"""
import argparse
import json
from pathlib import Path
import re
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import vendors

SUFFIXES = {'.swift', '.h', '.m', '.mm', '.cpp', '.inc', '.metal'}
TOKENS = re.compile(r'"""[\s\S]*?"""|@?"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|//[^\n]*|/\*[\s\S]*?\*/')
DIRECT = re.compile(r'\b(CVPixelBuffer(?:LockBaseAddress|UnlockBaseAddress|GetBaseAddress\w*|CreateWithBytes|CreateWithPlanarBytes)|IOSurface(?:Lock|Unlock|GetBaseAddress\w*)|vImage\w*|VTPixelTransferSession\w*|memcpy|memmove|memset)\b')
OBJC = re.compile(r'\[\s*[A-Za-z_]\w*(?:\.\w+)*\s+(contents|getBytes|replaceRegion)\b')
METHOD = re.compile(r'(?:(?:\b\w+[!?]?(?:\.\w+)*)\s*)?(?:\.|->)\s*(contents|getBytes|replace|copyMemory|makeBuffer)\s*\(')


def masked(text):
    def mask_token(match):
        token = match[0]
        result = list(''.join('\n' if ch == '\n' else ' ' for ch in token))
        if not token.startswith(('//', '/*', "'")):
            # Swift interpolation executes code; string-literal text does not.
            for interpolation in re.finditer(r'\\#*\(', token):
                preceding = interpolation.start() - 1
                escapes = 0
                while preceding >= 0 and token[preceding] == '\\':
                    escapes += 1
                    preceding -= 1
                if escapes % 2:
                    continue
                opening = interpolation.end() - 1
                end = close_delimiter(token, opening)
                expression = masked(token[opening + 1:end - 1])
                result[opening + 1:end - 1] = expression
        return ''.join(result)
    return TOKENS.sub(mask_token, text)


def canonical(text):
    return re.sub(r'\s+', '', text)


def close_delimiter(code, start, opening='(', closing=')'):
    depth = 0
    for index in range(start, len(code)):
        if code[index] == opening:
            depth += 1
        elif code[index] == closing:
            depth -= 1
            if depth == 0:
                return index + 1
    return len(code)


def symbols(code, native_source=False):
    ranges = []
    pattern = re.compile(r'\bfunc\s+(\w+)(?:<[^{}]*?>)?\s*\(|\b(init)\??\s*\(|\bvar\s+(\w+)\s*:[^={}\n]+\{')
    for match in pattern.finditer(code):
        name = next(value for value in match.groups() if value)
        if match[3]:
            body = match.end() - 1
        else:
            params = code.find('(', match.start())
            end = close_delimiter(code, params)
            body = code.find('{', end)
            if body < 0 or ';' in code[end:body] or re.search(r'\bfunc\b', code[end:body]):
                continue
        ranges.append((body, close_delimiter(code, body, '{', '}'), name))
    # C/ObjC++ helper functions. Avoid statements/control-flow and prototypes.
    native = re.compile(r'^[ \t]*(?:static[ \t]+)?[A-Za-z_][\w:<>,*& ]*[ \t]+(\w+)[ \t]*\([^;{}\n]*\)[ \t]*\{', re.M)
    for match in native.finditer(code) if native_source else ():
        if match[1] not in {'if', 'while', 'switch', 'for', 'catch'} and match[0].split()[0] not in {'if', 'while', 'for', 'switch', 'return', 'try'} and 'func ' not in match[0]:
            body = match.end() - 1
            ranges.append((body, close_delimiter(code, body, '{', '}'), match[1]))
    return ranges


def positive_test_lines(text):
    stack = []
    result = {}
    for number, line in enumerate(text.splitlines(), 1):
        text = line.strip()
        if text.startswith('#if '):
            expr = text[4:]
            stack.append(expr == 'ULTRACAM_TEST_SUPPORT' or bool(re.fullmatch(r'ULTRACAM_TEST_SUPPORT\s*&&\s*[^|]+', expr)))
        elif text.startswith(('#else', '#elseif')) and stack:
            stack[-1] = False
        elif text == '#endif' and stack:
            stack.pop()
        result[number] = any(stack)
    return result


# (relative path, enclosing symbol, exact call, data kind, reason). Each entry
# admits one static occurrence unless an explicit sixth field sets a reviewed
# count; never arbitrary matching operations in a file.
CLASSIFICATIONS = [
    ('Sources/Recording/RecordingPixelConverter.swift', 'encode', '.copyMemory(from:&rangeFlag,byteCount:4)', 'uniform', 'Upload exactly the four-byte UInt32 full-range flag at parameter offset four; shader performs video range conversion on GPU.', 1),
    ('Sources/Recording/PlanarRecordingConverter.swift', 'convert', 'IOSurfaceGetBaseAddress(inputSurface)', 'metadata', 'Input IOSurface address used only to compute checked plane offsets and allocation bounds; no pixel dereference.', 1),
    ('Sources/Recording/PlanarRecordingConverter.swift', 'convert', 'IOSurfaceGetBaseAddressOfPlane(inputSurface,plane)', 'metadata', 'Plane address participates only in offset/extent validation against IOSurface allocation; video read by GPU texture.', 1),
    ('Sources/Recording/RecordingRGBPixelConverter.swift', 'submit', 'IOSurfaceGetBaseAddress(sourceSurface)', 'metadata', 'Source IOSurface pointer used only as retained allocation-budget identity; no CPU video access.', 1),
    ('Sources/DeviceAPI/CPUCompatibilityConverter+Ingest.swift', 'copyIngest', 'CVPixelBufferLockBaseAddress(buffer,[])', 'compatibility-video', 'copyIngest only: validated per-plane source bounds and retained frame, Metal4 plus opt-in guards precede row copies; output plane dimensions/stride checked and onCopied reports success.', 1),
    ('Sources/DeviceAPI/CPUCompatibilityConverter+Ingest.swift', 'copyIngest', 'CVPixelBufferUnlockBaseAddress(buffer,[])', 'compatibility-video', 'copyIngest only: validated per-plane source bounds and retained frame, Metal4 plus opt-in guards precede row copies; output plane dimensions/stride checked and onCopied reports success.', 1),
    ('Sources/DeviceAPI/CPUCompatibilityConverter+Ingest.swift', 'copyIngest', 'CVPixelBufferGetBaseAddressOfPlane(buffer,index)', 'compatibility-video', 'copyIngest only: validated per-plane source bounds and retained frame, Metal4 plus opt-in guards precede row copies; output plane dimensions/stride checked and onCopied reports success.', 1),
    ('Sources/DeviceAPI/CPUCompatibilityConverter+Ingest.swift', 'copyIngest', 'CVPixelBufferGetBaseAddress(buffer)', 'compatibility-video', 'copyIngest only: validated per-plane source bounds and retained frame, Metal4 plus opt-in guards precede row copies; output plane dimensions/stride checked and onCopied reports success.', 1),
    ('Sources/DeviceAPI/CPUCompatibilityConverter+Ingest.swift', 'copyIngest', '.copyMemory(from:frame.pointer.advanced(by:source.offset+row*source.bytesPerRow),byteCount:layout.minimumRowBytes)', 'compatibility-video', 'copyIngest only: validated per-plane source bounds and retained frame, Metal4 plus opt-in guards precede row copies; output plane dimensions/stride checked and onCopied reports success.', 1),
    ('Sources/Recording/PlanarRecordingConverter.swift', 'convert', 'IOSurfaceGetBaseAddress(surface)', 'metadata', 'Pointer used only for retained IOSurface budget identity or plane-offset/checked extent validation against allocation size; no CPU dereference or pixel copy.', 2),
    ('Sources/Recording/PlanarRecordingConverter.swift', 'convert', 'IOSurfaceGetBaseAddressOfPlane(surface,plane)', 'metadata', 'Pointer used only for retained IOSurface budget identity or plane-offset/checked extent validation against allocation size; no CPU dereference or pixel copy.', 1),
    ('Sources/Recording/PlanarRecordingConverter.swift', 'convert', 'device.makeBuffer(bytes:values,length:values.count*4)', 'uniform', 'Upload fixed UInt32 layout flags or three SIMD4<Float> chroma/range vectors; video planes remain resident GPU textures with resources retained through feedback.', 1),
    ('Sources/Shared/NDIPlanarGPUDecoder.swift', 'encode', 'device.makeBuffer(bytes:values,length:values.count*16)', 'uniform', 'Upload fixed UInt32 layout flags or three SIMD4<Float> chroma/range vectors; video planes remain resident GPU textures with resources retained through feedback.', 1),
    ('Packages/MonitorKit/Sources/MonitorKit/MonitorRawFrameDecoder.swift', 'encode', 'device.makeBuffer(bytes:values,length:48)', 'uniform', 'Upload fixed shader layout/range parameters only; video remains GPU buffer/texture data and returned/submission resources retain residency through completion.', 1),
    ('Sources/Recording/RecordingRGBPixelConverter.swift', 'convert', 'device.makeBuffer(bytesNoCopy:IOSurfaceGetBaseAddress(surface),length:IOSurfaceGetAllocSize(surface),options:.storageModeShared,deallocator:nil)', 'zero-copy', 'Wrap IOSurface storage as Metal buffer without copying pixels; source CVPixelBuffer is retained by Submission through feedback and input is resident.', 1),
    ('Sources/Recording/RecordingRGBPixelConverter.swift', 'convert', 'IOSurfaceGetBaseAddress(surface)', 'zero-copy', 'Wrap IOSurface storage as Metal buffer without copying pixels; source CVPixelBuffer is retained by Submission through feedback and input is resident.', 1),
    ('Sources/Recording/RecordingRGBPixelConverter.swift', 'submit', 'device.makeBuffer(bytes:values,length:values.count*4)', 'uniform', 'Upload fixed shader layout/range parameters only; video remains GPU buffer/texture data and returned/submission resources retain residency through completion.', 1),
    ('Sources/Recording/RecordingRGBPixelConverter.swift', 'submit', 'IOSurfaceGetBaseAddress(surface)', 'metadata', 'Use destination IOSurface address solely as allocation-budget identity; no CPU dereference or video read.', 1),
    ('Sources/Shared/Packed422GPU4.swift', 'encode', 'parameters.contents()', 'uniform', 'Upload fixed shader layout/range parameters only; video remains GPU buffer/texture data and returned/submission resources retain residency through completion.', 1),
    ('Sources/Shared/Packed422GPU4.swift', 'encode', '.copyMemory(from:$0.baseAddress!,byteCount:$0.count)', 'uniform', 'Upload fixed shader layout/range parameters only; video remains GPU buffer/texture data and returned/submission resources retain residency through completion.', 1),
    ('Sources/Shared/Packed422GPU4.swift', 'encodeTexture', 'parameters.contents()', 'uniform', 'Upload fixed shader layout/range parameters only; video remains GPU buffer/texture data and returned/submission resources retain residency through completion.', 1),
    ('Sources/Shared/Packed422GPU4.swift', 'encodeTexture', '.copyMemory(from:$0.baseAddress!,byteCount:$0.count)', 'uniform', 'Upload fixed shader layout/range parameters only; video remains GPU buffer/texture data and returned/submission resources retain residency through completion.', 1),
    ('Sources/Shared/RGBGPUDecoder.swift', 'encode', 'device.makeBuffer(bytes:values,length:16)', 'uniform', 'Upload fixed shader layout/range parameters only; video remains GPU buffer/texture data and returned/submission resources retain residency through completion.', 1),
    ('Sources/DeviceAPI/CPUMemoryGPUIngest.swift', 'encode', 'device.makeBuffer(bytesNoCopy:pointer,length:lease.roundedLength,options:.storageModeShared,deallocator:nil)', 'zero-copy', 'Wrap the page-rounded SDK allocation without copying pixels; NoCopyIngestLease retains allocation and frame until GPU feedback retires the buffer.', 1),
    ('Sources/DeviceAPI/CPUMemoryGPUIngest.swift', 'encode', 'params.contents()', 'uniform', 'Write exactly one 16-byte SIMD4<UInt32> containing width, height, stride and allocation offset; GPU kernel alone reads video bytes.', 1),
    ('Sources/Shared/PlanarGPUDecoder.swift', 'encode', 'device.makeBuffer(bytes:&parameters,length:MemoryLayout<SIMD4<Float>>.stride*parameters.count,options:.storageModeShared)', 'uniform', 'Upload three SIMD4<Float> parameter vectors (48 bytes) describing subsampling, chroma siting and range scales; video planes remain Metal textures.', 1),
    ('Sources/Recording/EmbeddedAudioRecording.swift', 'packSignificant24Bits',
     'vImageConvert_ARGB8888toRGB888(&input, &output, vImage_Flags(kvImageDoNotTile))',
     'pcm', 'Shuffle significant PCM24 bytes from signed interleaved PCM32; no video payload.'),
    ('Sources/Recording/EmbeddedAudioRecording.swift', 'packSignificant24Bits',
     'vImage_Flags(kvImageDoNotTile)', 'pcm', 'Flags for the PCM byte shuffle.'),
    ('Sources/App/MonitorGPUContext.swift', 'allocateUniforms', 'buffer.contents()',
     'uniform', 'Return a host uniform-ring allocation, not frame pixels.'),
    ('Packages/MonitorKit/Sources/MonitorKit/Metal4.swift', 'slot', 'buffer!.contents()', 'uniform', 'Host uniform ring slot pointer; frame images are bound separately as textures.', 1),
    ('Packages/MonitorKit/Sources/MonitorKit/Metal4.swift', 'store', '.copyMemory(from:$0.baseAddress!,byteCount:$0.count)', 'uniform', 'Upload one typed render parameter value to a uniform allocation.', 1),
    ('Packages/MonitorKit/Sources/MonitorKit/MonitorEngine.swift', 'placeholder', 't.replace(region:MTLRegionMake3D(0,0,0,size,size,d.depth),mipmapLevel:0,slice:0,withBytes:$0.baseAddress!,bytesPerRow:size*bytesPerPixel,bytesPerImage:size*size*bytesPerPixel)', 'lut', 'Upload initialized placeholder shader-resource texels, not a source or output video frame.', 1),
    ('Packages/MonitorKit/Sources/MonitorKit/MonitorLUT.swift', 'init', 'texture.replace(region:MTLRegionMake3D(0,0,0,n,n,n),mipmapLevel:0,slice:0,withBytes:bytes.baseAddress!,bytesPerRow:n*16,bytesPerImage:n*n*16)', 'lut', 'Upload LUT lattice/shaper entries and edge padding; immutable lookup data, not frame payload.', 1),
    ('Packages/MonitorKit/Sources/MonitorKit/MonitorLUT.swift', 'init', 'texture.replace(region:MTLRegionMake3D(0,0,0,side,side,n),mipmapLevel:0,slice:0,withBytes:bytes.baseAddress!,bytesPerRow:side*16,bytesPerImage:perSlice*16)', 'lut', 'Upload LUT lattice/shaper entries and edge padding; immutable lookup data, not frame payload.', 1),
    ('Packages/MonitorKit/Sources/MonitorKit/MonitorLUT.swift', 'init', 'texture.replace(region:MTLRegionMake3D(0,0,n,side,side,shaperSlices),mipmapLevel:0,slice:0,withBytes:bytes.baseAddress!,bytesPerRow:side*16,bytesPerImage:perSlice*16)', 'lut', 'Upload LUT lattice/shaper entries and edge padding; immutable lookup data, not frame payload.', 1),
    ('Packages/MonitorKit/Sources/MonitorKitAudio/SnapshotPublisher.swift', 'publish', 't.copyMemory(from:UnsafeRawBufferPointer(rebasing:bytes[(full*8)...]))', 'statistics', 'Copy the trailing bytes of a small aggregate audio-meter snapshot into an atomic word.', 1),
    ('Packages/MonitorKit/Sources/MonitorKitAudio/SnapshotPublisher.swift', 'read', '.copyMemory(from:UnsafeRawBufferPointer(rebasing:t[..<(bytes.count-full*8)]))', 'statistics', 'Read the trailing bytes of an aggregate audio-meter snapshot; no PCM/video sample buffer.', 1),
    ('Packages/MonitorKit/Sources/MonitorKitScopes/ScopeAccumulator.swift', 'init', 'memset(stats.contents(),0,length)', 'statistics', 'Initialize the aggregate scope-statistics words; GPU bin/image allocations are separate.', 1),
    ('Packages/MonitorKit/Sources/MonitorKitScopes/ScopeAccumulator.swift', 'init', 'stats.contents()', 'statistics', 'Initialize the aggregate scope-statistics words; GPU bin/image allocations are separate.', 1),
    ('Packages/MonitorKit/Sources/MonitorKitScopes/ScopeMetal4.swift', 'scopeStore', '.copyMemory(from:$0.baseAddress!,byteCount:$0.count)', 'uniform', 'Upload one typed scope parameter value to a host uniform allocation.', 1),
    ('Packages/MonitorKit/Sources/MonitorKitScopes/ScopeParameters.swift', 'statistics', 'buffer.contents()', 'statistics', 'Read two aggregate ScopeStatistics slots, never the input video texture.', 1),
    ('Sources/App/LUTProcessor.swift', 'makePlaceholderLUT', 'texture.replace(region:MTLRegionMake3D(0,0,0,2,2,2),mipmapLevel:0,slice:0,withBytes:bytes.baseAddress!,bytesPerRow:32,bytesPerImage:64)', 'lut', 'Upload the fixed 2x2x2 identity LUT; shader lookup data, not video.', 1),
    ('Sources/App/LUTProcessor.swift', 'submit', 'parameterBuffer.contents()', 'uniform', 'Upload the typed LUT/resize/color parameter structure into the selected GPU uniform slot.', 1),
    ('Sources/App/LUTProcessor.swift', 'submit', '.copyMemory(from:bytes.baseAddress!,byteCount:bytes.count)', 'uniform', 'Upload the typed LUT/resize/color parameter structure into the selected GPU uniform slot.', 1),
    ('Sources/App/ProgramNormalizer.swift', 'normalize', 'slot.params.contents()', 'uniform', 'Upload source/destination dimensions to normalization shader parameter storage.', 1),
    ('Sources/App/ProgramNormalizer.swift', 'normalize', '.copyMemory(from:&params,byteCount:MemoryLayout<Params>.size)', 'uniform', 'Upload source/destination dimensions to normalization shader parameter storage.', 1),
    ('Sources/Recording/EmbeddedAudioRecording.swift', 'packSignificant24Bits', 'vImage_Buffer(data:UnsafeMutableRawPointer(mutating:source),height:1,width:vImagePixelCount(sampleCount),rowBytes:sampleCount*EmbeddedAudioFormat.sourceBytesPerSample)', 'pcm', 'Reinterpret interleaved PCM32 words as byte channels for a significant-24-bit PCM shuffle.', 1),
    ('Sources/Recording/EmbeddedAudioRecording.swift', 'packSignificant24Bits', 'vImagePixelCount(sampleCount)', 'pcm', 'Reinterpret interleaved PCM32 words as byte channels for a significant-24-bit PCM shuffle.', 2),
    ('Sources/Recording/EmbeddedAudioRecording.swift', 'packSignificant24Bits', 'vImage_Buffer(data:destination,height:1,width:vImagePixelCount(sampleCount),rowBytes:sampleCount*EmbeddedAudioFormat.recordingBytesPerSample)', 'pcm', 'Reinterpret interleaved PCM32 words as byte channels for a significant-24-bit PCM shuffle.', 1),
    ('Sources/Recording/EmbeddedAudioRecording.swift', 'makeSampleBuffer', 'destination.copyMemory(from:source,byteCount:packet.pcm24.count)', 'pcm', 'Copy already packed PCM24 bytes into a recording audio sample buffer.', 1),
    ('Sources/Recording/RecordingPixelConverter.swift', 'encode', 'slot.parameters.contents()', 'uniform', 'Upload pixel-width UInt32 parameter only; actual video repack runs on GPU.', 2),
    ('Sources/Recording/RecordingPixelConverter.swift', 'encode', '.copyMemory(from:&pixelWidth,byteCount:MemoryLayout<UInt32>.size)', 'uniform', 'Upload pixel-width UInt32 parameter only; actual video repack runs on GPU.', 1),
    ('Vendors/Sony/Sources/SonyCameraControl.mm', 'sonyDecodeChoices', 'memcpy(&value,bytes+i,width)', 'metadata', 'Decode bounded scalar camera-property choice values from SDK metadata bytes.', 1),
]


def sdk_exclusions(root, manifests):
    """Only validated, named external SDK subtrees are third-party scope."""
    result = []
    for manifest in manifests:
        sdk = manifest.get('sdk')
        if sdk:
            path = sdk['root']
            resolved = (Path(root) / path).resolve()
            vendor_root = (Path(root) / 'Vendors').resolve()
            if not resolved.is_relative_to(vendor_root):
                raise ValueError('CPU lint SDK exclusion must stay under Vendors')
            parts = resolved.relative_to(vendor_root).parts
            if len(parts) < 2 or parts[1].lower() in {'sources', 'tools', 'tests'}:
                raise ValueError('CPU lint SDK exclusion must name a non-owned SDK subtree under one vendor')
            result.append(dict(path=path, vendor=manifest['id'], version=sdk['version'],
                               reason='Manifest-declared third-party SDK boundary; owned adapter/tool source remains scanned.'))
    return result


def scan(root, manifests=None):
    root = Path(root)
    if manifests is None:
        manifests = vendors.load_manifests(root)
    excluded = [(root / entry['path']).resolve() for entry in sdk_exclusions(root, manifests)]
    # A declared production source is ours even if incorrectly placed inside
    # an SDK directory; manifest SDK metadata cannot exempt that source.
    owned = {(root / entry['path']).resolve() for manifest in manifests for entry in manifest['sources']}
    paths = []
    for surface in (root / 'Sources', root / 'Packages/MonitorKit/Sources'):
        paths.extend(p for p in surface.rglob('*') if p.is_file() and p.suffix in SUFFIXES)
    paths.extend(p for p in (root / 'Vendors').rglob('*')
                 if p.is_file() and p.suffix in SUFFIXES
                 and not any(part.lower() == 'tests' for part in p.relative_to(root / 'Vendors').parts))
    classifications = {}
    for entry in CLASSIFICATIONS:
        path, symbol, call, kind, reason = entry[:5]
        maximum = entry[5] if len(entry) == 6 else 1
        classifications[(path, symbol, canonical(call))] = (kind, reason, maximum)
    used = {}
    hits = []
    for path in sorted(set(paths)):
        if path.resolve() not in owned and any(path.resolve().is_relative_to(sdk) for sdk in excluded):
            continue
        relative = path.relative_to(root).as_posix()
        text = path.read_text()
        code = masked(text)
        scopes = symbols(code, native_source=path.suffix in {'.h', '.m', '.mm', '.cpp', '.inc'})
        candidates = []
        for match in DIRECT.finditer(code):
            next_index = match.end()
            while next_index < len(code) and code[next_index].isspace():
                next_index += 1
            end = close_delimiter(code, next_index) if next_index < len(code) and code[next_index] == '(' else match.end()
            candidates.append((match.start(), end, match[1]))
        for match in METHOD.finditer(code):
            end = close_delimiter(code, match.end() - 1)
            call = code[match.start():end]
            api = match[1]
            if api == 'replace' and not re.search(r'\bregion\s*:', call):
                continue
            if api == 'makeBuffer' and not re.search(r'\b(?:bytes|bytesNoCopy)\s*:', call):
                continue
            candidates.append((match.start(), end, api))
        for match in OBJC.finditer(code):
            end = close_delimiter(code, match.start(), '[', ']')
            candidates.append((match.start(), end, match[1]))
        guard = positive_test_lines(code)
        named_fake = (relative.startswith('Sources/DeviceAPI/Fake') and path.suffix == '.swift') or relative == 'Sources/App/AppHardwareSyntheticFixture.swift'
        for start, end, api in sorted(candidates):
            # METHOD may capture indentation; line belongs to its first token.
            while start < end and code[start].isspace():
                start += 1
            line = code.count('\n', 0, start) + 1
            containing = [(b - a, name) for a, b, name in scopes if a <= start < b]
            symbol = min(containing)[1] if containing else '<top-level>'
            signature = canonical(code[start:end])
            key = (relative, symbol, signature)
            kind, reason = 'unclassified', 'New CPU access/review trigger requires data-kind and call-site review.'
            if named_fake and guard.get(line, False):
                kind, reason = 'test-only', 'Named fake pattern writer, positively guarded by ULTRACAM_TEST_SUPPORT.'
            elif key in classifications and used.get(key, 0) < classifications[key][2]:
                kind, reason, _ = classifications[key]
                used[key] = used.get(key, 0) + 1
            hits.append(dict(path=relative, line=line, api=api, symbol=symbol, signature=signature,
                             classification=kind, reason=reason))
    return hits


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--json', action='store_true', help='Print every call-site classification and unresolved signature.')
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        manifests = vendors.load_manifests(root)
        exclusions = sdk_exclusions(root, manifests)
        hits = scan(root, manifests)
    except (OSError, ValueError) as error:
        print(f'cpu-pixel-access: invalid inputs: {error}', file=sys.stderr)
        return 2
    failures = [hit for hit in hits if hit['classification'] == 'unclassified']
    if args.json:
        print(json.dumps(dict(findings=hits, excludedSDKSubtrees=exclusions), indent=2))
    else:
        for exclusion in exclusions:
            print(f"cpu-pixel-access: SDK boundary {exclusion['path']} ({exclusion['version']}): {exclusion['reason']}")
        for hit in failures:
            print(f"{hit['path']}:{hit['line']}: unclassified-cpu-access: {hit['symbol']} :: {hit['signature']}")
        print(f'cpu-pixel-access: {len(hits) - len(failures)} classified, {len(failures)} unresolved; '
              'VideoToolbox encoder-format structural test remains separate.')
    return 1 if failures else 0

if __name__ == '__main__':
    raise SystemExit(main())
