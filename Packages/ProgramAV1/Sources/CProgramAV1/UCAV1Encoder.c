#include "UCAV1Encoder.h"
#include <aom/aomcx.h>
#include <aom/aom_encoder.h>
#include <stdlib.h>

struct UCAV1Encoder {
    aom_codec_ctx_t codec;
    aom_image_t image;
    int64_t last_key;
    int64_t key_interval;
};

UCAV1Encoder *uc_av1_create(int width, int height, int kbps, int threads,
                            int timebase_num, int timebase_den, int max_key_frames) {
    if (width < 2 || height < 2 || ((width | height) & 1) || width > 8192 || height > 8192 ||
        kbps < 1 || threads < 1 || timebase_num < 1 || timebase_den < 1 || max_key_frames < 1) return NULL;
    aom_codec_iface_t *iface = aom_codec_av1_cx();
    aom_codec_enc_cfg_t cfg;
    if (aom_codec_enc_config_default(iface, &cfg, AOM_USAGE_REALTIME) != AOM_CODEC_OK) return NULL;
    cfg.g_w = width;
    cfg.g_h = height;
    cfg.g_threads = threads;
    cfg.g_timebase = (aom_rational_t){timebase_num, timebase_den};
    cfg.g_lag_in_frames = 0;
    cfg.g_pass = AOM_RC_ONE_PASS;
    cfg.rc_end_usage = AOM_CBR;
    cfg.rc_target_bitrate = kbps;
    cfg.rc_dropframe_thresh = 0;
    cfg.kf_mode = AOM_KF_AUTO;
    cfg.kf_max_dist = max_key_frames;
    UCAV1Encoder *encoder = calloc(1, sizeof(*encoder));
    if (!encoder) return NULL;
    if (aom_codec_enc_init(&encoder->codec, iface, &cfg, 0) != AOM_CODEC_OK) {
        free(encoder);
        return NULL;
    }
    aom_codec_ctx_t *codec = &encoder->codec;
    // Row and tile workers share a single low-latency frame. No inter-frame lookahead.
    if (aom_codec_control(codec, AOME_SET_CPUUSED, 12) != AOM_CODEC_OK ||
        aom_codec_control(codec, AV1E_SET_ROW_MT, 1u) != AOM_CODEC_OK ||
        aom_codec_control(codec, AV1E_SET_TILE_COLUMNS, width >= 3840 ? 2u : width >= 1280 ? 1u : 0u) != AOM_CODEC_OK ||
        aom_codec_control(codec, AV1E_SET_TILE_ROWS, height >= 1080 ? 1u : 0u) != AOM_CODEC_OK ||
        aom_codec_control(codec, AOME_SET_ENABLEAUTOALTREF, 0u) != AOM_CODEC_OK ||
        aom_codec_control(codec, AV1E_SET_COLOR_PRIMARIES, AOM_CICP_CP_BT_709) != AOM_CODEC_OK ||
        aom_codec_control(codec, AV1E_SET_TRANSFER_CHARACTERISTICS, AOM_CICP_TC_BT_709) != AOM_CODEC_OK ||
        aom_codec_control(codec, AV1E_SET_MATRIX_COEFFICIENTS, AOM_CICP_MC_BT_709) != AOM_CODEC_OK ||
        aom_codec_control(codec, AV1E_SET_COLOR_RANGE, AOM_CR_STUDIO_RANGE) != AOM_CODEC_OK) {
        uc_av1_destroy(encoder);
        return NULL;
    }
    aom_image_t *image = &encoder->image;
    image->fmt = AOM_IMG_FMT_NV12;
    image->w = image->d_w = image->r_w = width;
    image->h = image->d_h = image->r_h = height;
    image->bit_depth = 8;
    image->bps = 12;
    image->x_chroma_shift = image->y_chroma_shift = 1;
    image->cp = AOM_CICP_CP_BT_709;
    image->tc = AOM_CICP_TC_BT_709;
    image->mc = AOM_CICP_MC_BT_709;
    image->range = AOM_CR_STUDIO_RANGE;
    encoder->last_key = -1;
    encoder->key_interval = max_key_frames;
    return encoder;
}

int uc_av1_encode(UCAV1Encoder *encoder, const uint8_t *y, int y_stride,
                  const uint8_t *uv, int uv_stride, int64_t pts, uint32_t duration,
                  UCAV1Packet *out) {
    if (!encoder || !y || !uv || !out || !duration || pts < 0 ||
        y_stride < (int)encoder->image.d_w || uv_stride < (int)encoder->image.d_w) return 0;
    encoder->image.planes[AOM_PLANE_Y] = (uint8_t *)y;
    encoder->image.planes[AOM_PLANE_U] = (uint8_t *)uv;
    encoder->image.stride[AOM_PLANE_Y] = y_stride;
    encoder->image.stride[AOM_PLANE_U] = uv_stride;
    const int force = encoder->last_key < 0 || pts - encoder->last_key >= encoder->key_interval;
    if (aom_codec_encode(&encoder->codec, &encoder->image, pts, duration,
                         force ? AOM_EFLAG_FORCE_KF : 0) != AOM_CODEC_OK) return 0;
    aom_codec_iter_t iter = NULL;
    const aom_codec_cx_pkt_t *packet;
    while ((packet = aom_codec_get_cx_data(&encoder->codec, &iter))) {
        if (packet->kind != AOM_CODEC_CX_FRAME_PKT) continue;
        if (packet->data.frame.pts != pts || !packet->data.frame.sz) return 0;
        out->bytes = packet->data.frame.buf;
        out->count = packet->data.frame.sz;
        out->keyframe = !!(packet->data.frame.flags & AOM_FRAME_IS_KEY);
        if (out->keyframe) encoder->last_key = pts;
        return 1;
    }
    return 0;
}

void uc_av1_destroy(UCAV1Encoder *encoder) {
    if (encoder) {
        aom_codec_destroy(&encoder->codec);
        free(encoder);
    }
}
