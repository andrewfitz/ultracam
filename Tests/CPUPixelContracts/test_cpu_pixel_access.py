"""CPU access policy fixtures; no Swift compilation or hardware required."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/check-cpu-pixel-access.py'

class CPUPixelAccessChecks(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('cpu_pixel_access', SCRIPT)
        self.checker = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.checker)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def write(self, path, text):
        dest = self.root / path
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text(text)

    def failures(self):
        return [hit for hit in self.checker.scan(self.root) if hit['classification'] == 'unclassified']

    def test_new_cpu_video_call_fails(self):
        self.write('Sources/App/New.swift', 'func video() { CVPixelBufferGetBaseAddress(image) }\n')
        hits = self.failures()
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]['api'], 'CVPixelBufferGetBaseAddress')
        self.assertEqual(hits[0]['symbol'], 'video')

    def test_pcm_shuffle_and_uniform_upload_are_classified_by_operation(self):
        self.write('Sources/Recording/EmbeddedAudioRecording.swift', '''func packSignificant24Bits() {
          let status = vImageConvert_ARGB8888toRGB888(&input, &output, vImage_Flags(kvImageDoNotTile))
        }''')
        self.write('Sources/App/MonitorGPUContext.swift', 'func allocateUniforms() { buffer.contents().advanced(by: offset) }')
        self.assertEqual(self.failures(), [])
        kinds = {hit['classification'] for hit in self.checker.scan(self.root)}
        self.assertEqual(kinds, {'pcm', 'uniform'})

    def test_unrelated_video_call_in_allowlisted_file_has_no_exemption(self):
        self.write('Sources/Recording/EmbeddedAudioRecording.swift', 'func video() { CVPixelBufferLockBaseAddress(image, []) }')
        self.write('Sources/App/MonitorGPUContext.swift', 'func allocateUniforms() { other.contents() }')
        self.assertEqual(len(self.failures()), 2)

    def test_uniform_signature_in_wrong_symbol_and_duplicate_call_fail(self):
        self.write('Sources/App/MonitorGPUContext.swift', 'func other() { buffer.contents() }')
        self.assertEqual(len(self.failures()), 1)
        self.write('Sources/App/MonitorGPUContext.swift', 'func allocateUniforms() { buffer.contents(); buffer.contents() }')
        self.assertEqual(len(self.failures()), 1)

    def test_comments_strings_and_non_texture_replace_are_exempt(self):
        self.write('Sources/App/New.swift', '''// VTPixelTransferSessionCreate(allocator, &session)
        /* CVPixelBufferLockBaseAddress(image, []) */
        let message = "memcpy(destination, source, count)"
        func audio() { rmsWindows[c].replace(old, with: new) }
        ''')
        self.assertEqual(self.checker.scan(self.root), [])

    def test_test_patterns_require_named_fake_path_and_positive_guard(self):
        self.write('Sources/DeviceAPI/FakeCapturePlugin.swift', '#if ULTRACAM_TEST_SUPPORT\nfunc fill() { CVPixelBufferGetBaseAddress(image) }\n#endif\n')
        self.write('Sources/App/AppHardwareSyntheticFixture.swift', '#if ULTRACAM_TEST_SUPPORT\nfunc fill() { CVPixelBufferLockBaseAddress(image, []) }\n#endif\n')
        self.assertEqual(self.failures(), [])
        self.write('Sources/DeviceAPI/FakeCapturePlugin.swift', '#if ULTRACAM_TEST_SUPPORT || DEBUG\nfunc fill() { CVPixelBufferGetBaseAddress(image) }\n#endif\n')
        self.assertEqual(len(self.failures()), 1)
        self.write('Sources/App/OtherFake.swift', '#if ULTRACAM_TEST_SUPPORT\nfunc fill() { CVPixelBufferGetBaseAddress(image) }\n#endif\n')
        self.assertEqual(len(self.failures()), 2)

    def test_iosurface_texture_vimage_and_transfer_apis_are_reviewed(self):
        self.write('Sources/App/New.swift', '''func video() {
          IOSurfaceLock(surface, [], nil)
          IOSurfaceGetBaseAddressOfPlane(surface, 0)
          texture.getBytes(bytes, bytesPerRow: stride, from: region, mipmapLevel: 0)
          texture.replace(\nregion: region, mipmapLevel: 0, withBytes: bytes, bytesPerRow: stride)
          vImageScale_ARGB8888(&source, &destination, nil, 0)
          VTPixelTransferSessionTransferImage(session, source, destination)
        }''')
        self.assertEqual(len(self.failures()), 6)

    def test_memory_and_zero_copy_buffer_wrappers_need_classification(self):
        self.write('Vendors/Acme/Sources/Plugin.mm', '''void copy() {
          memcpy(target, source, size); memmove(target, source, size); memset(target, 0, size);
          CVPixelBufferCreateWithBytes(allocator, width, height, format, bytes, stride, release, owner, nil, &image);
          CVPixelBufferCreateWithPlanarBytes(allocator, width, height, format, bytes, size, planes, addresses, widths, heights, strides, release, owner, nil, &image);
        }''')
        self.write('Packages/MonitorKit/Sources/MonitorKit/New.swift', 'func wrap() { device.makeBuffer(bytesNoCopy: pointer, length: count, options: []) }')
        self.assertEqual(len(self.failures()), 6)

    def test_production_standby_and_converter_name_are_not_blanket_exempt(self):
        self.write('Sources/CameraExtension/CameraProvider.swift', 'func makeStandby() { memset(base, 0, length) }')
        self.write('Sources/App/CPUCompatibilityConverter.swift', 'class CPUCompatibilityConverter { func copy() { CVPixelBufferGetBaseAddress(image) } }')
        self.assertEqual(len(self.failures()), 2)

    def test_tests_are_exempt_but_vendor_sdk_text_is_still_reviewed(self):
        self.write('Tests/Video.swift', 'CVPixelBufferGetBaseAddress(image)')
        self.write('Vendors/Acme/Tests/Video.swift', 'CVPixelBufferGetBaseAddress(image)')
        self.write('Vendors/Acme/SDK/Video.h', 'CVPixelBufferGetBaseAddress(image)')
        self.write('Packages/MonitorKit/Tests/Video.swift', 'CVPixelBufferGetBaseAddress(image)')
        self.assertEqual(len(self.failures()), 1)
        self.assertEqual(self.failures()[0]['path'], 'Vendors/Acme/SDK/Video.h')

    def test_objc_and_cpp_texture_and_buffer_access_are_reviewed(self):
        self.write('Vendors/Acme/Sources/Plugin.mm', '''void render() {
          [texture getBytes:target bytesPerRow:stride fromRegion:region mipmapLevel:0];
          [texture replaceRegion:region mipmapLevel:0 withBytes:source bytesPerRow:stride];
          [buffer contents];
          texture->getBytes(target, stride, region, 0);
        }''')
        self.assertEqual(len(self.failures()), 4)

    def test_comments_inside_classified_call_do_not_change_signature(self):
        self.write('Sources/App/MonitorGPUContext.swift', 'func allocateUniforms() { buffer./* uniform */contents() }')
        self.assertEqual(self.failures(), [])
        self.assertEqual(self.checker.scan(self.root)[0]['classification'], 'uniform')

    def test_executable_swift_string_interpolation_is_scanned(self):
        self.write('Sources/App/New.swift', r'func describe() { let value = "pointer: \(CVPixelBufferGetBaseAddress(image))" }')
        self.assertEqual(len(self.failures()), 1)

    def test_legal_newlines_in_method_calls_are_not_a_bypass(self):
        self.write('Sources/App/New.swift', 'func video() { buffer.contents\n(); buffer.\ncontents(); texture.\nreplace(\nregion: region, mipmapLevel: 0, withBytes: pixels, bytesPerRow: stride) }')
        self.assertEqual(len(self.failures()), 3)

    def test_statistics_exception_is_call_specific(self):
        self.write('Packages/MonitorKit/Sources/MonitorKitScopes/ScopeAccumulator.swift', 'init() { memset(stats.contents(), 0, length); memset(frame, 0, bytes) }')
        hits = self.checker.scan(self.root)
        self.assertEqual([h['classification'] for h in hits].count('statistics'), 2)
        self.assertEqual(len(self.failures()), 1)

    def test_only_manifest_declared_sdk_subtree_is_third_party(self):
        self.write('Vendors/Acme/SDK/Header.h', 'void *value = CVPixelBufferGetBaseAddress(image);')
        self.write('Vendors/Acme/Sources/Plugin.swift', 'func copy() { CVPixelBufferGetBaseAddress(image) }')
        manifests = [{'id': 'acme', 'sources': [], 'sdk': {'root': 'Vendors/Acme/SDK', 'version': '1.2', 'policy': 'local'}}]
        hits = self.checker.scan(self.root, manifests=manifests)
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]['path'], 'Vendors/Acme/Sources/Plugin.swift')
        scope = self.checker.sdk_exclusions(self.root, manifests)
        self.assertEqual(scope[0]['path'], 'Vendors/Acme/SDK')
        self.assertIn('third-party', scope[0]['reason'])

    def test_sdk_scope_cannot_hide_vendor_or_owned_source_directories(self):
        for path in ('Vendors', 'Vendors/Acme', 'Vendors/Acme/Sources', 'Vendors/Acme/Tools'):
            manifests = [{'id': 'acme', 'sources': [], 'sdk': {'root': path, 'version': '1', 'policy': 'local'}}]
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.checker.sdk_exclusions(self.root, manifests)

    def test_manifest_owned_file_inside_sdk_still_needs_classification(self):
        path = 'Vendors/Acme/SDK/OwnedBridge.swift'
        self.write(path, 'func video() { CVPixelBufferGetBaseAddress(image) }')
        manifests = [{'id': 'acme', 'sources': [{'path': path, 'membership': ['app']}],
                      'sdk': {'root': 'Vendors/Acme/SDK', 'version': '1', 'policy': 'local'}}]
        hits = self.checker.scan(self.root, manifests)
        self.assertEqual(len(hits), 1)
        self.assertEqual(hits[0]['classification'], 'unclassified')

    def test_gpu_ingest_no_copy_wrapper_and_parameter_uploads_are_narrow(self):
        self.write('Sources/DeviceAPI/CPUMemoryGPUIngest.swift', 'func encode() { device.makeBuffer(bytesNoCopy: pointer, length: lease.roundedLength, options: .storageModeShared, deallocator: nil); params.contents() }')
        self.write('Sources/Shared/PlanarGPUDecoder.swift', 'func encode() { device.makeBuffer(bytes: &parameters, length: MemoryLayout<SIMD4<Float>>.stride * parameters.count, options: .storageModeShared) }')
        self.assertEqual(self.failures(), [])
        self.assertEqual({h['classification'] for h in self.checker.scan(self.root)}, {'zero-copy', 'uniform'})
        self.write('Sources/DeviceAPI/CPUMemoryGPUIngest.swift', 'func encode() { params.contents(); CVPixelBufferGetBaseAddress(image); device.makeBuffer(bytes: pixels, length: size, options: .storageModeShared) }')
        self.assertEqual(len(self.failures()), 2)

    def test_explicit_ingest_compatibility_copy_is_callsite_specific(self):
        self.write('Sources/DeviceAPI/CPUCompatibilityConverter+Ingest.swift', 'func copyIngest() { CVPixelBufferLockBaseAddress(buffer, []); CVPixelBufferUnlockBaseAddress(buffer, []); CVPixelBufferGetBaseAddress(buffer) }')
        self.assertEqual(self.failures(), [])
        self.assertEqual({h['classification'] for h in self.checker.scan(self.root)}, {'compatibility-video'})
        self.write('Sources/Recording/CPUCompatibilityConverter.swift', 'func other() { CVPixelBufferGetBaseAddress(buffer) }')
        self.assertEqual(len(self.failures()), 1)

    def test_multiplane_compatibility_and_recording_metadata_are_exact(self):
        self.write('Sources/DeviceAPI/CPUCompatibilityConverter+Ingest.swift', 'func copyIngest() { CVPixelBufferGetBaseAddressOfPlane(buffer, index) }')
        self.write('Sources/Recording/PlanarRecordingConverter.swift', 'func convert() { IOSurfaceGetBaseAddress(surface); IOSurfaceGetBaseAddress(surface); IOSurfaceGetBaseAddressOfPlane(surface, plane); device.makeBuffer(bytes: values, length: values.count * 4) }')
        self.write('Sources/Shared/NDIPlanarGPUDecoder.swift', 'func encode() { device.makeBuffer(bytes: values, length: values.count * 16) }')
        self.assertEqual(self.failures(), [])
        self.write('Sources/Recording/PlanarRecordingConverter.swift', 'func other() { IOSurfaceGetBaseAddress(surface) }')
        self.assertEqual(len(self.failures()), 1)

    def test_new_planar_bounds_and_monitor_uniform_layout_are_narrow(self):
        self.write('Sources/Recording/PlanarRecordingConverter.swift', 'func convert() { IOSurfaceGetBaseAddress(inputSurface); IOSurfaceGetBaseAddressOfPlane(inputSurface, plane) }')
        self.write('Sources/Recording/RecordingRGBPixelConverter.swift', 'func submit() { IOSurfaceGetBaseAddress(sourceSurface) }')
        self.write('Packages/MonitorKit/Sources/MonitorKit/MonitorRawFrameDecoder.swift', 'func encode() { device.makeBuffer(bytes: values, length: 48) }')
        self.assertEqual(self.failures(), [])
        self.write('Sources/Recording/PlanarRecordingConverter.swift', 'func convert() { CVPixelBufferGetBaseAddress(image) }')
        self.assertEqual(len(self.failures()), 1)

    def test_recording_full_range_flag_is_only_four_byte_uniform(self):
        self.write('Sources/Recording/RecordingPixelConverter.swift', 'func encode() { slot.parameters.contents().copyMemory(from: &pixelWidth, byteCount: MemoryLayout<UInt32>.size); slot.parameters.contents().advanced(by: 4).copyMemory(from: &rangeFlag, byteCount: 4) }')
        self.assertEqual(self.failures(), [])
        self.assertTrue(all(h['classification'] == 'uniform' for h in self.checker.scan(self.root)))
        self.write('Sources/Recording/RecordingPixelConverter.swift', 'func encode() { slot.parameters.contents().advanced(by: 4).copyMemory(from: &rangeFlag, byteCount: 8); CVPixelBufferGetBaseAddress(image) }')
        self.assertEqual(len(self.failures()), 2)

if __name__ == '__main__':
    unittest.main()
