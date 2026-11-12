#include <stdio.h>
#include "lame.h"

int main(void)
{
    lame_global_flags *encoder = lame_init();
    short samples[1152 * 2] = {0};
    unsigned char output[8192];
    int total = 0;

    if (encoder == NULL)
        return 1;
    if (lame_set_num_channels(encoder, 2) < 0 ||
        lame_set_in_samplerate(encoder, 44100) < 0 ||
        lame_set_out_samplerate(encoder, 44100) < 0 ||
        lame_set_brate(encoder, 128) < 0 ||
        lame_set_quality(encoder, 5) < 0 ||
        lame_init_params(encoder) < 0) {
        lame_close(encoder);
        return 2;
    }

    for (int i = 0; i < 4; ++i) {
        int bytes = lame_encode_buffer_interleaved(encoder, samples, 1152,
                                                    output, sizeof output);
        if (bytes < 0) {
            lame_close(encoder);
            return 3;
        }
        total += bytes;
    }

    int bytes = lame_encode_flush(encoder, output, sizeof output);
    if (bytes < 0) {
        lame_close(encoder);
        return 4;
    }
    total += bytes;
    lame_close(encoder);

    if (total <= 0)
        return 5;
    printf("LAME encode ok: %d bytes\n", total);
    return 0;
}
