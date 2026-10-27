// Compiled after MonitorKit's MKLUT.msl (MonitorShaders.source([.lut])), never
// alone: LUTProcessor builds one compilation unit, MKLUT.msl then this file, with
// MonitorShaders.compileOptions (safe math), so the burned-in LUT is MonitorKit's
// mk_applyLUT on the same MonitorLUT texture and LUTParameters the monitor uses.
// A prebuilt ULTRACAM_METALLIB must be compiled from the same concatenation.
#if !defined(MK_LUT_MSL_VERSION) || MK_LUT_MSL_VERSION != 2
#error "Compile MonitorShaders.source([.lut]) before LUTShaders.metal (mk_LUTParams layout 2, 80 bytes)."
#endif
#include <metal_stdlib>
using namespace metal;

// Mirrors LUTProcessor.Parameters (16-byte rows).
struct Parameters {
  uint4 geometry;       // x: source width, y: source height, z: output bit depth
  float4 decodeRange;   // luma black, luma range, chroma zero, chroma range (10-bit codes)
  float4 decodeMatrix;
  float4 encodeMatrix;  // x: Kr, y: Kb
  float4 chroma;        // x: source chroma sample offset (0 cosited, 0.5 centered)
  mk_LUTParams lut;     // MonitorLUT.parameters; shape.z is 0 when Apply LUT is off
};
static_assert(sizeof(Parameters) == 160, "Parameters is LUTProcessor.Parameters: ten 16-byte rows");

float3 decode(float y, float2 c, constant Parameters &p) {
  float luma = (y - p.decodeRange.x) / p.decodeRange.y;
  c = (c - p.decodeRange.z) / p.decodeRange.w;
  return float3(luma + p.decodeMatrix.x * c.y, luma - p.decodeMatrix.z * c.x - p.decodeMatrix.w * c.y, luma + p.decodeMatrix.y * c.x);
}

float3 encode(float3 rgb, constant Parameters &p) {
  float kr = p.encodeMatrix.x, kb = p.encodeMatrix.y;
  float y = dot(rgb, float3(kr, 1 - kr - kb, kb));
  return float3(y, (rgb.b - y) / (2 * (1 - kb)), (rgb.r - y) / (2 * (1 - kr)));
}

// v210 through an RGBA32Uint view, as in the DeckLink SDK's Metal sample: one
// texel is one 6-pixel group (four 32-bit words) of the capture IOSurface.
struct PackedSource {
  texture2d<uint, access::read> groups;

  float2 chromaPair(int pair, uint row, constant Parameters &p) const {
    pair = clamp(pair, 0, int(p.geometry.x / 2) - 1);
    uint4 g = groups.read(uint2(uint(pair / 3), row));
    uint lane = uint(pair % 3);
    if (lane == 0) return float2(g.x & 1023, (g.x >> 20) & 1023);
    if (lane == 1) return float2((g.y >> 10) & 1023, g.z & 1023);
    return float2((g.z >> 20) & 1023, (g.w >> 10) & 1023);
  }

  float3 pixel(uint x, uint y, constant Parameters &p) const {
    uint4 g = groups.read(uint2(x / 6, y));
    uint lane = x % 6, value;
    if (lane == 0) value = (g.x >> 10) & 1023;
    else if (lane == 1) value = g.y & 1023;
    else if (lane == 2) value = (g.y >> 20) & 1023;
    else if (lane == 3) value = (g.z >> 10) & 1023;
    else if (lane == 4) value = g.w & 1023;
    else value = (g.w >> 20) & 1023;
    float position = (float(x) - p.chroma.x) / 2.0f;
    int pair = int(floor(position));
    float2 c = mix(chromaPair(pair, y, p), chromaPair(pair + 1, y, p), position - floor(position));
    return decode(float(value), c, p);
  }
};

// 16-bit-container bi-planar 4:2:2 (x422 / xf22).
struct PlanarSource {
  texture2d<float, access::read> luma;
  texture2d<float, access::sample> chroma;

  float3 pixel(uint x, uint y, constant Parameters &p) const {
    constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 coord = float2(float(x) + 1.0f - p.chroma.x, float(y) + 0.5f) / float2(p.geometry.xy);
    float l = luma.read(uint2(x, y)).r * (65535.0f / 64.0f);
    float2 c = chroma.sample(linear, coord).rg * (65535.0f / 64.0f);
    return decode(l, c, p);
  }
};

// The only place a source pixel becomes graded RGB: decode, then MonitorKit's
// LUT (tetrahedral; a 1D shaper first when the LUT has one).
template <typename Source>
inline float3 graded(Source source, uint x, uint y, texture3d<float, access::sample> lut, constant Parameters &p) {
  return mk_applyLUT(source.pixel(x, y, p), lut, p.lut);
}

inline float quantizeY(float value, constant Parameters &p) {
  if (p.geometry.z == 8) return clamp(round(16 + 219 * value), 0.0f, 255.0f) / 255;
  return clamp(round(64 + 876 * value), 0.0f, 1023.0f) * 64 / 65535;
}
inline float2 quantizeC(float2 value, constant Parameters &p) {
  if (p.geometry.z == 8) return clamp(round(128 + 224 * value), 0.0f, 255.0f) / 255;
  return clamp(round(512 + 896 * value), 0.0f, 1023.0f) * 64 / 65535;
}
inline void writeNV12(float3 c00, float3 c10, float3 c01, float3 c11, uint2 base,
  texture2d<float, access::write> y, texture2d<float, access::write> uv, constant Parameters &p) {
  y.write(float4(quantizeY(encode(c00, p).x, p)), base);
  y.write(float4(quantizeY(encode(c10, p).x, p)), base + uint2(1, 0));
  y.write(float4(quantizeY(encode(c01, p).x, p)), base + uint2(0, 1));
  y.write(float4(quantizeY(encode(c11, p).x, p)), base + uint2(1, 1));
  uv.write(float4(quantizeC(encode((c00 + c10 + c01 + c11) / 4, p).yz, p), 0, 1), base / 2);
}
inline void write422(float3 c0, float3 c1, uint2 base,
  texture2d<float, access::write> y, texture2d<float, access::write> uv, constant Parameters &p) {
  y.write(float4(quantizeY(encode(c0, p).x, p)), base);
  y.write(float4(quantizeY(encode(c1, p).x, p)), base + uint2(1, 0));
  uv.write(float4(quantizeC(encode((c0 + c1) / 2, p).yz, p), 0, 1), uint2(base.x / 2, base.y));
}

// ---- Full resolution: decode + LUT + encode in one pass, no intermediate.
// One thread per 2x2 (4:2:0) or 2x1 (4:2:2) output block.
template <typename Source>
inline void fullNV12(Source s, texture3d<float, access::sample> lut, texture2d<float, access::write> y,
  texture2d<float, access::write> uv, constant Parameters &p, uint2 gid) {
  uint2 base = gid * 2;
  if (base.x >= p.geometry.x || base.y >= p.geometry.y) return;
  writeNV12(graded(s, base.x, base.y, lut, p), graded(s, base.x + 1, base.y, lut, p),
    graded(s, base.x, base.y + 1, lut, p), graded(s, base.x + 1, base.y + 1, lut, p), base, y, uv, p);
}

template <typename Source>
inline void full422(Source s, texture3d<float, access::sample> lut, texture2d<float, access::write> y,
  texture2d<float, access::write> uv, constant Parameters &p, uint2 gid) {
  uint2 base = uint2(gid.x * 2, gid.y);
  if (base.x >= p.geometry.x || base.y >= p.geometry.y) return;
  write422(graded(s, base.x, base.y, lut, p), graded(s, base.x + 1, base.y, lut, p), base, y, uv, p);
}

kernel void fullPackedNV12(texture2d<uint, access::read> groups [[texture(0)]], texture3d<float, access::sample> lut [[texture(2)]],
  texture2d<float, access::write> y [[texture(3)]], texture2d<float, access::write> uv [[texture(4)]],
  constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
  fullNV12(PackedSource{groups}, lut, y, uv, p, gid);
}
kernel void fullPacked422(texture2d<uint, access::read> groups [[texture(0)]], texture3d<float, access::sample> lut [[texture(2)]],
  texture2d<float, access::write> y [[texture(3)]], texture2d<float, access::write> uv [[texture(4)]],
  constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
  full422(PackedSource{groups}, lut, y, uv, p, gid);
}
kernel void fullPlanarNV12(texture2d<float, access::read> luma [[texture(0)]], texture2d<float, access::sample> chroma [[texture(1)]],
  texture3d<float, access::sample> lut [[texture(2)]],
  texture2d<float, access::write> y [[texture(3)]], texture2d<float, access::write> uv [[texture(4)]],
  constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
  fullNV12(PlanarSource{luma, chroma}, lut, y, uv, p, gid);
}
kernel void fullPlanar422(texture2d<float, access::read> luma [[texture(0)]], texture2d<float, access::sample> chroma [[texture(1)]],
  texture3d<float, access::sample> lut [[texture(2)]],
  texture2d<float, access::write> y [[texture(3)]], texture2d<float, access::write> uv [[texture(4)]],
  constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
  full422(PlanarSource{luma, chroma}, lut, y, uv, p, gid);
}

// ---- Lanczos-3 resize. The optimized 2:1 path uses constant weights; other
// ratios calculate scale-adjusted, normalized weights. The 2:1 weights
// are identical at every output pixel, so they are constants.
constant float lanczosHalfWeights[12] = {
  0.003689135430f, 0.015056142681f, -0.033998631514f, -0.066637317768f,
  0.135505284129f, 0.446385387043f, 0.446385387043f, 0.135505284129f,
  -0.066637317768f, -0.033998631514f, 0.015056142681f, 0.003689135430f
};

// Pass 1: decode + LUT + horizontal Lanczos. A threadgroup grades the 2N+11
// source pixels its N outputs need once, in threadgroup memory, so the LUT
// runs once per source pixel (LUT before scale, as before).
constant constexpr uint horizontalGroup = 128;
constant constexpr uint horizontalSpan = horizontalGroup * 2 + 11;

template <typename Source>
inline void horizontalPass(Source s, texture3d<float, access::sample> lut, texture2d<float, access::write> out,
  constant Parameters &p, threadgroup float4 *row, uint2 group, uint lid) {
  if (p.geometry.x != out.get_width() * 2) {
    uint ox = group.x * horizontalGroup + lid;
    if (ox >= out.get_width() || group.y >= out.get_height()) return;
    float scale = float(p.geometry.x) / out.get_width();
    float center = (float(ox) + 0.5f) * scale - 0.5f;
    float4 sum = 0; float total = 0;
    for (int ix = int(ceil(center - 3 * scale)); ix <= int(floor(center + 3 * scale)); ++ix) {
      float t = abs((float(ix) - center) / scale);
      float w = t < 0.00001f ? 1.0f : (t >= 3 ? 0.0f : sin(M_PI_F * t) * sin(M_PI_F * t / 3) / (M_PI_F * M_PI_F * t * t / 3));
      sum += float4(graded(s, uint(clamp(ix, 0, int(p.geometry.x) - 1)), group.y, lut, p), 1) * w;
      total += w;
    }
    out.write(sum / total, uint2(ox, group.y));
    return;
  }
  int firstOut = int(group.x * horizontalGroup);
  int firstIn = firstOut * 2 - 5;
  uint y = group.y;
  int last = int(p.geometry.x) - 1;
  for (uint i = lid; i < horizontalSpan; i += horizontalGroup) {
    uint x = uint(clamp(firstIn + int(i), 0, last));
    row[i] = float4(graded(s, x, y, lut, p), 1);
  }
  threadgroup_barrier(mem_flags::mem_threadgroup);
  uint ox = uint(firstOut) + lid;
  if (ox >= out.get_width() || y >= out.get_height()) return;
  float4 sum = 0;
  for (uint tap = 0; tap < 12; ++tap) sum += row[lid * 2 + tap] * lanczosHalfWeights[tap];
  out.write(sum, uint2(ox, y));
}

kernel void horizontalPacked(texture2d<uint, access::read> groups [[texture(0)]], texture3d<float, access::sample> lut [[texture(2)]],
  texture2d<float, access::write> out [[texture(3)]], constant Parameters &p [[buffer(0)]],
  uint2 group [[threadgroup_position_in_grid]], uint lid [[thread_index_in_threadgroup]]) {
  threadgroup float4 row[horizontalSpan];
  horizontalPass(PackedSource{groups}, lut, out, p, row, group, lid);
}
kernel void horizontalPlanar(texture2d<float, access::read> luma [[texture(0)]], texture2d<float, access::sample> chroma [[texture(1)]],
  texture3d<float, access::sample> lut [[texture(2)]],
  texture2d<float, access::write> out [[texture(3)]], constant Parameters &p [[buffer(0)]],
  uint2 group [[threadgroup_position_in_grid]], uint lid [[thread_index_in_threadgroup]]) {
  threadgroup float4 row[horizontalSpan];
  horizontalPass(PlanarSource{luma, chroma}, lut, out, p, row, group, lid);
}

// Pass 2: vertical Lanczos + output encode, one thread per output block.
inline float3 vertical(texture2d<float, access::read> input, uint x, uint y, uint outputHeight) {
  if (input.get_height() != outputHeight * 2) {
    float scale = float(input.get_height()) / outputHeight;
    float center = (float(y) + 0.5f) * scale - 0.5f;
    float3 sum = 0; float total = 0;
    for (int iy = int(ceil(center - 3 * scale)); iy <= int(floor(center + 3 * scale)); ++iy) {
      float t = abs((float(iy) - center) / scale);
      float w = t < 0.00001f ? 1.0f : (t >= 3 ? 0.0f : sin(M_PI_F * t) * sin(M_PI_F * t / 3) / (M_PI_F * M_PI_F * t * t / 3));
      sum += input.read(uint2(x, uint(clamp(iy, 0, int(input.get_height()) - 1)))).rgb * w; total += w;
    }
    return sum / total;
  }
  int begin = int(y) * 2 - 5;
  int last = int(input.get_height()) - 1;
  float4 sum = 0;
  for (int tap = 0; tap < 12; ++tap) {
    sum += input.read(uint2(x, uint(clamp(begin + tap, 0, last)))) * lanczosHalfWeights[tap];
  }
  return sum.rgb;
}

kernel void verticalNV12(texture2d<float, access::read> input [[texture(0)]],
  texture2d<float, access::write> y [[texture(3)]], texture2d<float, access::write> uv [[texture(4)]],
  constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
  uint2 base = gid * 2;
  if (base.x >= y.get_width() || base.y >= y.get_height()) return;
  writeNV12(vertical(input, base.x, base.y, y.get_height()), vertical(input, base.x + 1, base.y, y.get_height()),
    vertical(input, base.x, base.y + 1, y.get_height()), vertical(input, base.x + 1, base.y + 1, y.get_height()), base, y, uv, p);
}

kernel void vertical422(texture2d<float, access::read> input [[texture(0)]],
  texture2d<float, access::write> y [[texture(3)]], texture2d<float, access::write> uv [[texture(4)]],
  constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
  uint2 base = uint2(gid.x * 2, gid.y);
  if (base.x >= y.get_width() || base.y >= y.get_height()) return;
  write422(vertical(input, base.x, base.y, y.get_height()), vertical(input, base.x + 1, base.y, y.get_height()), base, y, uv, p);
}
