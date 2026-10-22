#include <metal_stdlib>
using namespace metal;

// ---------------------------------------------------------------------------
// MonitorKit 3D LUT sampling, copied verbatim from
// Packages/MonitorKit/Sources/MonitorKit/Shaders/MKLUT.msl so this file stays
// self-contained (the app compiles it from source). The LUT is applied by this
// one function only; swapping in MonitorKit's own copy is a one-line change.
// Ultracam uses trilinear mode (shape.y == 1), which reproduces the original
// 8-read manual interpolation exactly, now reading an rgba32Float texture3d.
#ifndef MK_LUT_MSL
#define MK_LUT_MSL

// Mirrors MonitorKit.LUTParameters.
struct mk_LUTParams {
  float4 domainLow;    // xyz: DOMAIN_MIN
  float4 domainScale;  // xyz: 1 / (DOMAIN_MAX - DOMAIN_MIN)
  uint4 shape;         // x: lattice size, y: interpolation (0 tetrahedral, 1 trilinear, 2 hardware), z: enabled
};

// Lattice is an rgba32Float texture3d; x is red, y green, z blue.
inline float3 mk_lattice(texture3d<float, access::sample> lut, uint3 i) { return lut.read(i).rgb; }

float3 mk_applyLUT(float3 rgb, texture3d<float, access::sample> lut, mk_LUTParams p) {
  if (p.shape.z == 0) return rgb;
  uint n = p.shape.x;
  float3 position = clamp((rgb - p.domainLow.xyz) * p.domainScale.xyz, 0.0f, 1.0f) * float(n - 1);
  if (p.shape.y == 2) {
    constexpr sampler filtered(coord::normalized, address::clamp_to_edge, filter::linear);
    return lut.sample(filtered, (position + 0.5f) / float(n)).rgb;
  }
  uint3 lo = uint3(floor(position)), hi = min(lo + 1, uint3(n - 1));
  float3 t = position - float3(lo);
  if (p.shape.y == 1) {
    // The original Ultracam order: x, then y, then z.
    float3 a = mix(mk_lattice(lut, uint3(lo.x, lo.y, lo.z)), mk_lattice(lut, uint3(hi.x, lo.y, lo.z)), t.x);
    float3 b = mix(mk_lattice(lut, uint3(lo.x, hi.y, lo.z)), mk_lattice(lut, uint3(hi.x, hi.y, lo.z)), t.x);
    float3 c = mix(mk_lattice(lut, uint3(lo.x, lo.y, hi.z)), mk_lattice(lut, uint3(hi.x, lo.y, hi.z)), t.x);
    float3 d = mix(mk_lattice(lut, uint3(lo.x, hi.y, hi.z)), mk_lattice(lut, uint3(hi.x, hi.y, hi.z)), t.x);
    return mix(mix(a, b, t.y), mix(c, d, t.y), t.z);
  }
  float3 c000 = mk_lattice(lut, lo), c111 = mk_lattice(lut, hi);
  if (t.x > t.y) {
    if (t.y > t.z)
      return (1 - t.x) * c000 + (t.x - t.y) * mk_lattice(lut, uint3(hi.x, lo.y, lo.z))
        + (t.y - t.z) * mk_lattice(lut, uint3(hi.x, hi.y, lo.z)) + t.z * c111;
    if (t.x > t.z)
      return (1 - t.x) * c000 + (t.x - t.z) * mk_lattice(lut, uint3(hi.x, lo.y, lo.z))
        + (t.z - t.y) * mk_lattice(lut, uint3(hi.x, lo.y, hi.z)) + t.y * c111;
    return (1 - t.z) * c000 + (t.z - t.x) * mk_lattice(lut, uint3(lo.x, lo.y, hi.z))
      + (t.x - t.y) * mk_lattice(lut, uint3(hi.x, lo.y, hi.z)) + t.y * c111;
  }
  if (t.z > t.y)
    return (1 - t.z) * c000 + (t.z - t.y) * mk_lattice(lut, uint3(lo.x, lo.y, hi.z))
      + (t.y - t.x) * mk_lattice(lut, uint3(lo.x, hi.y, hi.z)) + t.x * c111;
  if (t.z > t.x)
    return (1 - t.y) * c000 + (t.y - t.z) * mk_lattice(lut, uint3(lo.x, hi.y, lo.z))
      + (t.z - t.x) * mk_lattice(lut, uint3(lo.x, hi.y, hi.z)) + t.x * c111;
  return (1 - t.y) * c000 + (t.y - t.x) * mk_lattice(lut, uint3(lo.x, hi.y, lo.z))
    + (t.x - t.z) * mk_lattice(lut, uint3(hi.x, hi.y, lo.z)) + t.z * c111;
}

#endif
// ---------------------------------------------------------------------------

// Mirrors LUTProcessor.Parameters (16-byte rows).
struct Parameters {
  uint4 geometry;       // x: source width, y: source height
  float4 decodeRange;   // luma black, luma range, chroma zero, chroma range (10-bit codes)
  float4 decodeMatrix;
  float4 encodeMatrix;  // x: Kr, y: Kb
  float4 chroma;        // x: source chroma sample offset (0 cosited, 0.5 centered)
  mk_LUTParams lut;
};

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

// The only place a source pixel becomes graded RGB: decode, then the LUT.
template <typename Source>
inline float3 graded(Source source, uint x, uint y, texture3d<float, access::sample> lut, constant Parameters &p) {
  return mk_applyLUT(source.pixel(x, y, p), lut, p.lut);
}

inline void writeNV12(float3 c00, float3 c10, float3 c01, float3 c11, uint2 base,
  texture2d<float, access::write> y, texture2d<float, access::write> uv, constant Parameters &p) {
  y.write(float4((16 + 219 * encode(c00, p).x) / 255), base);
  y.write(float4((16 + 219 * encode(c10, p).x) / 255), base + uint2(1, 0));
  y.write(float4((16 + 219 * encode(c01, p).x) / 255), base + uint2(0, 1));
  y.write(float4((16 + 219 * encode(c11, p).x) / 255), base + uint2(1, 1));
  float3 color = (c00 + c10 + c01 + c11) / 4;
  float2 c = (128 + 224 * encode(color, p).yz) / 255;
  uv.write(float4(c, 0, 1), base / 2);
}

inline void write422(float3 c0, float3 c1, uint2 base,
  texture2d<float, access::write> y, texture2d<float, access::write> uv, constant Parameters &p) {
  y.write(float4(clamp(round(64 + 876 * encode(c0, p).x), 0.0f, 1023.0f) * 64 / 65535), base);
  y.write(float4(clamp(round(64 + 876 * encode(c1, p).x), 0.0f, 1023.0f) * 64 / 65535), base + uint2(1, 0));
  float3 color = (c0 + c1) / 2;
  float2 c = clamp(round(512 + 896 * encode(color, p).yz), 0.0f, 1023.0f) * 64 / 65535;
  uv.write(float4(c, 0, 1), uint2(base.x / 2, base.y));
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

// ---- UHD -> 1080 (exactly 2:1) antialiasing Lanczos-3. The normalized weights
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
inline float3 vertical(texture2d<float, access::read> input, uint x, uint y) {
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
  writeNV12(vertical(input, base.x, base.y), vertical(input, base.x + 1, base.y),
    vertical(input, base.x, base.y + 1), vertical(input, base.x + 1, base.y + 1), base, y, uv, p);
}

kernel void vertical422(texture2d<float, access::read> input [[texture(0)]],
  texture2d<float, access::write> y [[texture(3)]], texture2d<float, access::write> uv [[texture(4)]],
  constant Parameters &p [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
  uint2 base = uint2(gid.x * 2, gid.y);
  if (base.x >= y.get_width() || base.y >= y.get_height()) return;
  write422(vertical(input, base.x, base.y), vertical(input, base.x + 1, base.y), base, y, uv, p);
}
