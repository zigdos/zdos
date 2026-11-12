#include <stdint.h>
#include <stdio.h>
#include "x264.h"

static int add_nal_bytes(x264_nal_t *nals, int count) {
    int bytes = 0;
    for (int i = 0; i < count; ++i) {
        if (nals[i].i_payload <= 0 || !nals[i].p_payload) return -1;
        bytes += nals[i].i_payload;
    }
    return bytes;
}

int main(void) {
    x264_param_t param;
    x264_picture_t input, output;
    x264_t *encoder;
    x264_nal_t *nals;
    int count, bytes = 0;

    if (x264_param_default_preset(&param, "ultrafast", "zerolatency") < 0)
        return 1;
    param.i_width = 32;
    param.i_height = 32;
    param.i_fps_num = 25;
    param.i_fps_den = 1;
    param.i_threads = 2;
    param.i_log_level = X264_LOG_NONE;

    encoder = x264_encoder_open(&param);
    if (!encoder) {
        x264_param_cleanup(&param);
        return 2;
    }

    if (x264_picture_alloc(&input, X264_CSP_I420, 32, 32) < 0) {
        x264_encoder_close(encoder);
        x264_param_cleanup(&param);
        return 3;
    }

    for (int row = 0; row < 32; ++row)
        for (int col = 0; col < 32; ++col)
            input.img.plane[0][row * input.img.i_stride[0] + col] = 96;
    for (int plane = 1; plane < 3; ++plane)
        for (int row = 0; row < 16; ++row)
            for (int col = 0; col < 16; ++col)
                input.img.plane[plane][row * input.img.i_stride[plane] + col] = 128;

    if (x264_encoder_headers(encoder, &nals, &count) < 0 ||
        (bytes = add_nal_bytes(nals, count)) <= 0) {
        x264_picture_clean(&input);
        x264_encoder_close(encoder);
        x264_param_cleanup(&param);
        return 4;
    }

    for (int frame = 0; frame < 3; ++frame) {
        input.i_pts = frame;
        input.img.plane[0][frame] = (uint8_t)(96 + frame);
        int encoded = x264_encoder_encode(encoder, &nals, &count, &input, &output);
        if (encoded < 0) {
            x264_picture_clean(&input);
            x264_encoder_close(encoder);
            x264_param_cleanup(&param);
            return 5;
        }
        int n = add_nal_bytes(nals, count);
        if (n < 0) {
            x264_picture_clean(&input);
            x264_encoder_close(encoder);
            x264_param_cleanup(&param);
            return 6;
        }
        bytes += n;
    }

    while (x264_encoder_delayed_frames(encoder) > 0) {
        int encoded = x264_encoder_encode(encoder, &nals, &count, NULL, &output);
        int n = add_nal_bytes(nals, count);
        if (encoded < 0 || n < 0) {
            x264_picture_clean(&input);
            x264_encoder_close(encoder);
            x264_param_cleanup(&param);
            return 7;
        }
        bytes += n;
    }

    x264_picture_clean(&input);
    x264_encoder_close(encoder);
    x264_param_cleanup(&param);
    if (bytes <= 0) return 8;
    printf("x264 encode ok: %d bytes\n", bytes);
    return 0;
}
