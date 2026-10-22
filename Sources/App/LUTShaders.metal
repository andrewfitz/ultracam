#include <metal_stdlib>
using namespace metal;

struct Parameters {
  uint4 geometry;
  float4 domainLow;
  float4 domainScale;
  float4 decodeRange;
  float4 decodeMatrix;
  float4 encodeMatrix;
  uint4 options;
};

float3 lookup(float3 rgb, device const float4 *cube, constant Parameters &p) {
  if (!p.options.x) return rgb;
  uint n = p.geometry.w;
  float3 position = clamp((rgb - p.domainLow.xyz) * p.domainScale.xyz, 0.0f, 1.0f) * float(n - 1);
  uint3 lo = uint3(floor(position)), hi = min(lo + 1, uint3(n - 1));
  float3 t = position - float3(lo);
  float3 a = mix(cube[(lo.z * n + lo.y) * n + lo.x].rgb, cube[(lo.z * n + lo.y) * n + hi.x].rgb, t.x);
  float3 b = mix(cube[(lo.z * n + hi.y) * n + lo.x].rgb, cube[(lo.z * n + hi.y) * n + hi.x].rgb, t.x);
  float3 c = mix(cube[(hi.z * n + lo.y) * n + lo.x].rgb, cube[(hi.z * n + lo.y) * n + hi.x].rgb, t.x);
  float3 d = mix(cube[(hi.z * n + hi.y) * n + lo.x].rgb, cube[(hi.z * n + hi.y) * n + hi.x].rgb, t.x);
  return mix(mix(a, b, t.y), mix(c, d, t.y), t.z);
}

float3 decode(float y, float2 c, constant Parameters &p) {
  float luma = (y - p.decodeRange.x) / p.decodeRange.y;
  c = (c - p.decodeRange.z) / p.decodeRange.w;
  return float3(luma + p.decodeMatrix.x * c.y, luma - p.decodeMatrix.z * c.x - p.decodeMatrix.w * c.y, luma + p.decodeMatrix.y * c.x);
}

kernel void planarLUT(texture2d<float, access::read> y [[texture(0)]], texture2d<float, access::sample> uv [[texture(1)]],
  texture2d<float, access::write> rgb [[texture(2)]], device const float4 *cube [[buffer(0)]],
  constant Parameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.geometry.x || gid.y >= p.geometry.y) return;
  constexpr sampler chroma(coord::normalized, address::clamp_to_edge, filter::linear);
  float2 coord = float2(float(gid.x) + 1.0f - p.domainLow.w, float(gid.y) + 0.5f) / float2(p.geometry.xy);
  float luma = y.read(gid).r * (65535.0f / 64.0f);
  float2 c = uv.sample(chroma, coord).rg * (65535.0f / 64.0f);
  rgb.write(float4(lookup(decode(luma, c, p), cube, p), 1), gid);
}

// v210 through the texture cache, as in the DeckLink SDK's Metal sample: one
// RGBA32Uint texel is one 6-pixel group (four 32-bit words) of the IOSurface.
float2 packedChroma(texture2d<uint, access::read> groups, int pair, uint row, constant Parameters &p) {
  pair = clamp(pair, 0, int(p.geometry.x / 2) - 1);
  uint4 g = groups.read(uint2(uint(pair / 3), row));
  uint lane = uint(pair % 3);
  if (lane == 0) return float2(g.x & 1023, (g.x >> 20) & 1023);
  if (lane == 1) return float2((g.y >> 10) & 1023, g.z & 1023);
  return float2((g.z >> 20) & 1023, (g.w >> 10) & 1023);
}

kernel void packedLUT(texture2d<uint, access::read> groups [[texture(3)]], texture2d<float, access::write> rgb [[texture(2)]],
  device const float4 *cube [[buffer(0)]], constant Parameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= p.geometry.x || gid.y >= p.geometry.y) return;
  uint4 g = groups.read(uint2(gid.x / 6, gid.y));
  uint lane = gid.x % 6, value;
  if (lane == 0) value = (g.x >> 10) & 1023;
  else if (lane == 1) value = g.y & 1023;
  else if (lane == 2) value = (g.y >> 20) & 1023;
  else if (lane == 3) value = (g.z >> 10) & 1023;
  else if (lane == 4) value = g.w & 1023;
  else value = (g.w >> 20) & 1023;
  float position = (float(gid.x) - p.domainLow.w) / 2.0f;
  int pair = int(floor(position));
  float2 c = mix(packedChroma(groups, pair, gid.y, p), packedChroma(groups, pair + 1, gid.y, p), position - floor(position));
  rgb.write(float4(lookup(decode(float(value), c, p), cube, p), 1), gid);
}

// This pipeline's scaler is exactly UHD -> 1080 (2:1). Its normalized
// antialiasing Lanczos-3 weights are identical at every output pixel. Compute
// them once rather than evaluating 48 sine functions per pixel per pass.
constant float lanczosHalfWeights[12] = {
  0.003689135430f, 0.015056142681f, -0.033998631514f, -0.066637317768f,
  0.135505284129f, 0.446385387043f, 0.446385387043f, 0.135505284129f,
  -0.066637317768f, -0.033998631514f, 0.015056142681f, 0.003689135430f
};

kernel void lanczosHorizontal(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
  int begin = int(gid.x) * 2 - 5;
  float4 sum = 0;
  for (int tap = 0; tap < 12; ++tap) {
    sum += input.read(uint2(clamp(begin + tap, 0, int(input.get_width()) - 1), gid.y)) * lanczosHalfWeights[tap];
  }
  output.write(sum, gid);
}

kernel void lanczosVertical(texture2d<float, access::read> input [[texture(0)]], texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
  int begin = int(gid.y) * 2 - 5;
  float4 sum = 0;
  for (int tap = 0; tap < 12; ++tap) {
    sum += input.read(uint2(gid.x, clamp(begin + tap, 0, int(input.get_height()) - 1))) * lanczosHalfWeights[tap];
  }
  output.write(sum, gid);
}

float3 encode(float3 rgb, constant Parameters &p) {
  float kr = p.encodeMatrix.x, kb = p.encodeMatrix.y;
  float y = dot(rgb, float3(kr, 1 - kr - kb, kb));
  return float3(y, (rgb.b - y) / (2 * (1 - kb)), (rgb.r - y) / (2 * (1 - kr)));
}

kernel void encodeNV12(texture2d<float, access::read> rgb [[texture(0)]], texture2d<float, access::write> y [[texture(1)]],
  texture2d<float, access::write> uv [[texture(2)]], constant Parameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
  y.write(float4((16 + 219 * encode(rgb.read(gid).rgb, p).x) / 255), gid);
  if (!(gid.x % 2) && !(gid.y % 2)) {
    float3 color = (rgb.read(gid).rgb + rgb.read(gid + uint2(1, 0)).rgb + rgb.read(gid + uint2(0, 1)).rgb + rgb.read(gid + uint2(1, 1)).rgb) / 4;
    float2 c = (128 + 224 * encode(color, p).yz) / 255;
    uv.write(float4(c, 0, 1), gid / 2);
  }
}

kernel void encode422(texture2d<float, access::read> rgb [[texture(0)]], texture2d<float, access::write> y [[texture(1)]],
  texture2d<float, access::write> uv [[texture(2)]], constant Parameters &p [[buffer(1)]], uint2 gid [[thread_position_in_grid]]) {
  if (gid.x >= rgb.get_width() || gid.y >= rgb.get_height()) return;
  float code = clamp(round(64 + 876 * encode(rgb.read(gid).rgb, p).x), 0.0f, 1023.0f);
  y.write(float4(code * 64 / 65535), gid);
  if (!(gid.x % 2)) {
    float3 color = (rgb.read(gid).rgb + rgb.read(gid + uint2(1, 0)).rgb) / 2;
    float2 c = clamp(round(512 + 896 * encode(color, p).yz), 0.0f, 1023.0f) * 64 / 65535;
    uv.write(float4(c, 0, 1), uint2(gid.x / 2, gid.y));
  }
}
