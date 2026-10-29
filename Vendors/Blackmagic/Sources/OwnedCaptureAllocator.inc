#include <sys/mman.h>
#include <unistd.h>

// r210/R12L have no portable CoreVideo IOSurface pixel format. Allocating an
// IOSurface and asking CV to reinterpret an arbitrary SDK stride is not a
// proven route. SDK16 explicitly permits caller-owned buffers instead: mmap
// owns the complete page-rounded range that B7 imports without a pixel copy.
struct OwnedCaptureRecord { size_t length; uint64_t generation; };
static std::mutex ownedCaptureMutex;
static std::map<void *, OwnedCaptureRecord> ownedCaptureRecords;
static std::atomic<uint64_t> ownedCaptureGeneration{0};

class OwnedCaptureBuffer final : public IDeckLinkVideoBuffer {
  std::atomic<ULONG> references{1};
 public:
  void *pointer = nullptr;
  size_t length = 0;
  uint64_t generation = ++ownedCaptureGeneration;
  explicit OwnedCaptureBuffer(uint32_t bytes) {
    const size_t page = size_t(getpagesize());
    if (!bytes || size_t(bytes) > SIZE_MAX - (page - 1)) return;
    length = (size_t(bytes) + page - 1) / page * page;
    pointer = mmap(nullptr, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (pointer == MAP_FAILED) { pointer = nullptr; length = 0; return; }
    std::lock_guard<std::mutex> guard(ownedCaptureMutex);
    ownedCaptureRecords.emplace(pointer, OwnedCaptureRecord{length, generation});
  }
  ~OwnedCaptureBuffer() override {
    if (!pointer) return;
    { std::lock_guard<std::mutex> guard(ownedCaptureMutex); ownedCaptureRecords.erase(pointer); }
    munmap(pointer, length);
  }
  HRESULT QueryInterface(REFIID iid, LPVOID *result) override {
    if (!result) return E_INVALIDARG;
    *result = nullptr;
    if (sameIID(iid, IID_IDeckLinkVideoBuffer) || sameIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID))) {
      *result = static_cast<IDeckLinkVideoBuffer *>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  HRESULT GetBytes(void **result) override { if (!result || !pointer) return E_FAIL; *result = pointer; return S_OK; }
  HRESULT GetSize(uint64_t *result) override { if (!result || !pointer) return E_FAIL; *result = length; return S_OK; }
  HRESULT StartAccess(BMDBufferAccessFlags) override { return pointer ? S_OK : E_FAIL; }
  HRESULT EndAccess(BMDBufferAccessFlags) override { return S_OK; }
};

class OwnedCaptureAllocator final : public IDeckLinkVideoBufferAllocator {
  std::atomic<ULONG> references{1};
  uint32_t bytes;
 public:
  explicit OwnedCaptureAllocator(uint32_t size) : bytes(size) {}
  HRESULT QueryInterface(REFIID iid, LPVOID *result) override {
    if (!result) return E_INVALIDARG; *result = nullptr;
    if (sameIID(iid, IID_IDeckLinkVideoBufferAllocator) || sameIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID))) {
      *result = static_cast<IDeckLinkVideoBufferAllocator *>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  HRESULT AllocateVideoBuffer(IDeckLinkVideoBuffer **result) override {
    if (!result) return E_INVALIDARG;
    auto buffer = new OwnedCaptureBuffer(bytes);
    if (!buffer->pointer) { buffer->Release(); *result = nullptr; return E_OUTOFMEMORY; }
    *result = buffer; return S_OK;
  }
};
class OwnedCaptureAllocatorProvider final : public IDeckLinkVideoBufferAllocatorProvider {
  std::atomic<ULONG> references{1};
 public:
  HRESULT QueryInterface(REFIID iid, LPVOID *result) override {
    if (!result) return E_INVALIDARG; *result = nullptr;
    if (sameIID(iid, IID_IDeckLinkVideoBufferAllocatorProvider) || sameIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID))) {
      *result = static_cast<IDeckLinkVideoBufferAllocatorProvider *>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  HRESULT GetVideoBufferAllocator(uint32_t bytes, uint32_t width, uint32_t height, uint32_t rowBytes,
    BMDPixelFormat pixel, IDeckLinkVideoBufferAllocator **result) override {
    if (!result) return E_INVALIDARG; *result = nullptr;
    if ((pixel != bmdFormat10BitRGB && pixel != bmdFormat12BitRGBLE) ||
        !validPackedExtent(width, height, rowBytes, bytes, true, pixel)) return E_INVALIDARG;
    *result = new OwnedCaptureAllocator(bytes); return S_OK;
  }
};

@interface UCDeckLinkOwnedMemoryFrame ()
- (instancetype)initWithFrame:(IDeckLinkVideoInputFrame *)frame buffer:(IDeckLinkVideoBuffer *)buffer;
- (void)setColorspace:(BMDColorspace)colorspace eotf:(int64_t)eotf;
- (void)setCaptureHostTimeSeconds:(NSNumber *)seconds;
@end
@implementation UCDeckLinkOwnedMemoryFrame {
  IDeckLinkVideoInputFrame *_frame;
  IDeckLinkVideoBuffer *_buffer;
  const void *_pointer;
  NSUInteger _allocationLength;
  uint64_t _generation;
  NSString *_colorPrimaries, *_transferFunction;
  NSNumber *_captureHostTimeSeconds;
}
- (instancetype)initWithFrame:(IDeckLinkVideoInputFrame *)frame buffer:(IDeckLinkVideoBuffer *)buffer {
  if (!(self = [super init])) return nil;
  if (buffer->StartAccess(bmdBufferAccessRead) != S_OK) return nil;
  void *pointer = nullptr;
  if (buffer->GetBytes(&pointer) != S_OK || !pointer) { buffer->EndAccess(bmdBufferAccessRead); return nil; }
  {
    std::lock_guard<std::mutex> guard(ownedCaptureMutex);
    auto found = ownedCaptureRecords.find(pointer);
    if (found == ownedCaptureRecords.end()) { buffer->EndAccess(bmdBufferAccessRead); return nil; }
    _pointer = pointer; _allocationLength = found->second.length; _generation = found->second.generation;
  }
  _frame = frame; frame->AddRef(); _buffer = buffer; buffer->AddRef();
  return self;
}
- (const void *)pointer { return _pointer; }
- (NSUInteger)allocationLength { return _allocationLength; }
- (uint64_t)generation { return _generation; }
- (NSInteger)width { return _frame->GetWidth(); }
- (NSInteger)height { return _frame->GetHeight(); }
- (NSInteger)rowBytes { return _frame->GetRowBytes(); }
- (uint32_t)pixelFormat { return _frame->GetPixelFormat(); }
- (NSString *)colorPrimaries { return _colorPrimaries; }
- (NSString *)transferFunction { return _transferFunction; }
- (BOOL)fullRange { return self.pixelFormat == bmdFormat12BitRGBLE; }
- (NSNumber *)captureHostTimeSeconds { return _captureHostTimeSeconds; }
- (void)setCaptureHostTimeSeconds:(NSNumber *)seconds { _captureHostTimeSeconds = seconds; }
- (void)setColorspace:(BMDColorspace)colorspace eotf:(int64_t)eotf {
  _colorPrimaries = colorspace == bmdColorspaceRec709 ? (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_709_2 :
    colorspace == bmdColorspaceRec2020 ? (__bridge NSString *)kCVImageBufferColorPrimaries_ITU_R_2020 :
    colorspace == bmdColorspaceRec601 ? (__bridge NSString *)kCVImageBufferColorPrimaries_SMPTE_C : nil;
  _transferFunction = eotf == kEOTFSDR ? (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_709_2 :
    eotf == kEOTFPQ ? (__bridge NSString *)kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ :
    eotf == kEOTFHLG ? (__bridge NSString *)kCVImageBufferTransferFunction_ITU_R_2100_HLG : nil;
}
- (void)dealloc {
  if (_buffer) { _buffer->EndAccess(bmdBufferAccessRead); _buffer->Release(); }
  if (_frame) _frame->Release();
}
@end
