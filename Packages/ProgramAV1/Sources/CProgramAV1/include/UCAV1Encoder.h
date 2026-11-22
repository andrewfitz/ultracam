#ifndef UC_AV1_ENCODER_H
#define UC_AV1_ENCODER_H
#include <stdint.h>
#include <stddef.h>

typedef struct UCAV1Encoder UCAV1Encoder;
typedef struct {
    const uint8_t *bytes;
    size_t count;
    int keyframe;
} UCAV1Packet;

/// The session consumes video-range NV12 synchronously. Packet storage belongs to the
/// encoder and remains readable until the next encode or destruction of the session.
UCAV1Encoder *uc_av1_create(int width, int height, int kbps, int threads,
                            int timebase_num, int timebase_den, int max_key_frames);
int uc_av1_encode(UCAV1Encoder *encoder, const uint8_t *y, int y_stride,
                  const uint8_t *uv, int uv_stride, int64_t pts, uint32_t duration,
                  UCAV1Packet *packet);
void uc_av1_destroy(UCAV1Encoder *encoder);
#endif
