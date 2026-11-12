/* ZLIBTEST: tests ZLIB.ZDL (tests/ports/zlib-tests.py runs it)
 * on the drive labelled ZLDISK: round trips, streams,
 * checksums, gz files, and files the script compares with this
 * computer's zlib (MANIFEST.TXT says which). Lines go to the
 * screen and to X:\ZLIBTEST.LOG; the exit code: failures. */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>
#include "zlib.h"
#include "zdos.h"

static int passed, failed;
static char dir[4] = "?:\\";
static char log_path[32];

static void say(const char *fmt, ...) {
    char line[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    fputs(line, stdout);
    if (log_path[0]) {
        FILE *f = fopen(log_path, "a");
        if (f) {
            fputs(line, f);
            fclose(f);
        }
    }
}

static int check(int ok, const char *what, ...) {
    char name[256];
    va_list ap;
    va_start(ap, what);
    vsnprintf(name, sizeof name, what, ap);
    va_end(ap);
    if (ok) passed++; else failed++;
    /* Many round trips: only the failures and a line per group are shown */
    if (!ok) say("not ok - %s\n", name);
    return ok;
}

static void group(const char *name, int before_failed, int before_passed) {
    int n = passed - before_passed, f = failed - before_failed;
    say("%s - %s (%d checks)\n", f ? "not ok" : "ok", name, n + f);
}

static char *path(const char *name) {
    static char p[64];
    snprintf(p, sizeof p, "%s%s", dir, name);
    return p;
}

/* DATA */

static uint32_t seed = 12345;
static uint32_t rnd(void) {
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return seed;
}

static const char *words[] = {"the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "ZDOS", "zlib",
                              "deflate", "inflate", "window", "Huffman", "a", "of", "and", "to", "in", "is",
                              "compression", "library", "data", "stream", "\n", ", ", ". ", "1234", "x"};

enum { RANDOM, TEXT, ZEROS, PERIODIC, KINDS };
static const char *kind_name[] = {"random", "text", "zeros", "periodic"};

static void fill(unsigned char *b, size_t n, int kind) {
    size_t i = 0;
    switch (kind) {
        case RANDOM:
            for (; i < n; i++) b[i] = (unsigned char)rnd();
            break;
        case TEXT:
            while (i < n) {
                const char *w = words[rnd() % (sizeof words / sizeof *words)];
                while (*w && i < n) b[i++] = (unsigned char)*w++;
                if (i < n) b[i++] = ' ';
            }
            break;
        case ZEROS:
            memset(b, 0, n);
            break;
        default:
            for (; i < n; i++) b[i] = (unsigned char)("abcdefghijklmnopq"[i % 17] ^ (i % 251 == 0));
    }
}

static unsigned char *read_file(const char *name, size_t *len) {
    FILE *f = fopen(path(name), "rb");
    if (!f) return NULL;
    size_t cap = 1 << 16, n = 0;
    unsigned char *b = malloc(cap);
    size_t got;
    while ((got = fread(b + n, 1, cap - n, f)) > 0) {
        n += got;
        if (n == cap) b = realloc(b, cap *= 2);
    }
    fclose(f);
    *len = n;
    return b;
}

static int write_file(const char *name, const void *b, size_t n) {
    FILE *f = fopen(path(name), "wb");
    if (!f) return 0;
    int ok = fwrite(b, 1, n, f) == n;
    return fclose(f) == 0 && ok;
}

/* ALLOCATION COUNTING (ZALLOC / ZFREE OF THE PROGRAM'S OWN) */

static long live_blocks, all_blocks;
static voidpf my_alloc(voidpf opaque, uInt items, uInt size) {
    (void)opaque;
    live_blocks++;
    all_blocks++;
    return calloc(items, size);
}
static void my_free(voidpf opaque, voidpf p) {
    (void)opaque;
    live_blocks--;
    free(p);
}

/* TESTS */

#define SIZE_CODE(t) (sizeof(t) == 2 ? 0u : sizeof(t) == 4 ? 1u : sizeof(t) == 8 ? 2u : 3u)

static void versions(void) {
    say("# zlib %s, compile flags 0x%lx\n", zlibVersion(), zlibCompileFlags());
    check(strcmp(zlibVersion(), ZLIB_VERSION) == 0, "version");
    uLong fl = zlibCompileFlags();
    check((fl & 3) == SIZE_CODE(uInt) && (fl >> 2 & 3) == SIZE_CODE(uLong) && (fl >> 4 & 3) == SIZE_CODE(voidpf) &&
              (fl >> 6 & 3) == SIZE_CODE(z_off_t),
          "compile flags: the sizes of uInt, uLong, pointers, z_off_t");
    check(strcmp(zError(Z_DATA_ERROR), "data error") == 0, "zError");
    check(get_crc_table() != NULL && get_crc_table()[1] == 0x77073096, "get_crc_table");
}

static void checksums(void) {
    int f0 = failed, p0 = passed;
    const unsigned char *s = (const unsigned char *)"123456789";
    check(crc32(0, s, 9) == 0xCBF43926, "crc32 check value");
    check(crc32(0, Z_NULL, 0) == 0, "crc32 initial");
    check(adler32(0, Z_NULL, 0) == 1, "adler32 initial");
    check(adler32(1, s, 9) == 0x091E01DE, "adler32 check value");
    check(crc32_z(0, (const unsigned char *)"The quick brown fox jumps over the lazy dog", 43) == 0x414FA339, "crc32_z");
    check(adler32_z(1, (const unsigned char *)"Wikipedia", 9) == 0x11E60398, "adler32_z");
    size_t n = 1 << 20;
    unsigned char *b = malloc(n);
    fill(b, n, RANDOM);
    for (size_t cut = 0; cut < n; cut = cut * 3 + 7) {
        uLong a1 = crc32(0, b, (uInt)cut), a2 = crc32(0, b + cut, (uInt)(n - cut));
        check(crc32_combine(a1, a2, (z_off_t)(n - cut)) == crc32(0, b, (uInt)n), "crc32_combine at %zu", cut);
        check(crc32_combine_op(a1, a2, crc32_combine_gen((z_off_t)(n - cut))) == crc32(0, b, (uInt)n),
              "crc32_combine_op at %zu", cut);
        uLong d1 = adler32(1, b, (uInt)cut), d2 = adler32(1, b + cut, (uInt)(n - cut));
        check(adler32_combine(d1, d2, (z_off_t)(n - cut)) == adler32(1, b, (uInt)n), "adler32_combine at %zu", cut);
    }
    /* Byte by byte the same as at once */
    uLong c = 0, a = 1;
    for (size_t i = 0; i < 4099; i++) {
        c = crc32(c, b + i, 1);
        a = adler32(a, b + i, 1);
    }
    check(c == crc32(0, b, 4099) && a == adler32(1, b, 4099), "byte by byte");
    free(b);
    group("crc32, adler32: known values, combine", f0, p0);
}

static void round_trips(void) {
    int f0 = failed, p0 = passed;
    static const size_t sizes[] = {0, 1, 2, 3, 7, 100, 258, 1000, 4095, 4096, 4097, 32767, 32768, 65535,
                                   65536, 100000, 300000, 1 << 20};
    size_t max = 1 << 20;
    unsigned char *src = malloc(max), *dst = malloc(compressBound(max)), *back = malloc(max + 1);
    int count = 0;
    for (size_t si = 0; si < sizeof sizes / sizeof *sizes; si++) {
        for (int kind = 0; kind < KINDS; kind++) {
            size_t n = sizes[si];
            fill(src, n, kind);
            for (int level = -1; level <= 9; level++) {
                if (n >= 300000 && level != -1 && level != 1 && level != 9) continue;
                uLongf dlen = compressBound(n);
                int rc = compress2(dst, &dlen, src, n, level);
                if (!check(rc == Z_OK && dlen <= compressBound(n), "compress2 %s %zu level %d: %d", kind_name[kind], n,
                           level, rc))
                    continue;
                uLongf blen = max + 1;
                rc = uncompress(back, &blen, dst, dlen);
                check(rc == Z_OK && blen == n && memcmp(src, back, n) == 0, "uncompress %s %zu level %d: %d",
                      kind_name[kind], n, level, rc);
                /* uncompress2: all of the input used */
                uLong slen = dlen + 5;
                dst[dlen] = 0xAA;
                blen = max + 1;
                rc = uncompress2(back, &blen, dst, &slen);
                check(rc == Z_OK && slen == dlen && blen == n, "uncompress2 %s %zu", kind_name[kind], n);
                count++;
            }
            uLongf dlen = compressBound(n);
            check(compress(dst, &dlen, src, n) == Z_OK, "compress %zu", n);
            z_size_t zlen = compressBound_z(n), zb = max + 1;
            check(compress_z(dst, &zlen, src, n) == Z_OK && uncompress_z(back, &zb, dst, zlen) == Z_OK && zb == n,
                  "compress_z, uncompress_z %zu", n);
        }
    }
    say("# %d compress2 / uncompress round trips\n", count);
    free(src);
    free(dst);
    free(back);
    group("compress, uncompress: random, text, zeros, periodic, 0 B to 1 MiB, levels -1 to 9", f0, p0);
}

/* Deflates in pieces of in_step bytes into out_step-byte pieces, flushing
 * now and then; inflates the same way. 1 if it comes back whole. */
static int stream(const unsigned char *src, size_t n, int level, int wbits, int mem, int strategy, int in_wbits,
                  size_t in_step, size_t out_step, unsigned char *z, size_t zcap, unsigned char *back) {
    z_stream s;
    memset(&s, 0, sizeof s);
    s.zalloc = my_alloc;
    s.zfree = my_free;
    if (deflateInit2(&s, level, Z_DEFLATED, wbits, mem, strategy) != Z_OK) return 0;
    size_t in = 0, out = 0;
    int rc, round = 0;
    do {
        size_t step = in_step + (size_t)(round % 3) * in_step / 2;
        s.next_in = (Bytef *)src + in;
        s.avail_in = (uInt)(n - in < step ? n - in : step);
        int last = in + s.avail_in == n;
        int flush = last ? Z_FINISH : round % 7 == 3 ? Z_SYNC_FLUSH : round % 11 == 5 ? Z_FULL_FLUSH
                    : round % 13 == 8 ? Z_PARTIAL_FLUSH : round % 17 == 9 ? Z_BLOCK : Z_NO_FLUSH;
        round++;
        do {
            s.next_out = z + out;
            /* Flushes need over 6 bytes of room, or each call adds a marker: */
            size_t room = flush != Z_NO_FLUSH && flush != Z_FINISH && out_step < 8 ? 8 : out_step;
            s.avail_out = (uInt)(zcap - out < room ? zcap - out : room);
            rc = deflate(&s, flush);
            out = s.next_out - z;
            if (rc == Z_STREAM_ERROR || out >= zcap) {
                deflateEnd(&s);
                return 0;
            }
        } while (s.avail_out == 0 || (flush == Z_FINISH && rc != Z_STREAM_END));
        in = s.next_in - src;
    } while (in < n || rc != Z_STREAM_END);
    if (deflateEnd(&s) != Z_OK) return 0;

    memset(&s, 0, sizeof s);
    s.zalloc = my_alloc;
    s.zfree = my_free;
    if (inflateInit2(&s, in_wbits) != Z_OK) return 0;
    size_t zin = 0, got = 0;
    do {
        s.next_in = z + zin;
        s.avail_in = (uInt)(out - zin < in_step ? out - zin : in_step);
        do {
            s.next_out = back + got;
            s.avail_out = (uInt)(out_step < n + 1 - got ? out_step : n + 1 - got);
            rc = inflate(&s, Z_NO_FLUSH);
            got = s.next_out - back;
            if (rc != Z_OK && rc != Z_STREAM_END && rc != Z_BUF_ERROR) {
                inflateEnd(&s);
                return 0;
            }
        } while (s.avail_out == 0 && rc != Z_STREAM_END && got <= n);
        zin = s.next_in - z;
    } while (rc != Z_STREAM_END && zin < out);
    inflateEnd(&s);
    return rc == Z_STREAM_END && got == n && memcmp(src, back, n) == 0;
}

static void streams(void) {
    int f0 = failed, p0 = passed;
    size_t n = 200000;
    unsigned char *src = malloc(n), *z = malloc(n * 2 + 1000), *back = malloc(n + 1);
    static const int wbits[][2] = {{15, 15}, {31, 31}, {31, 47}, {15, 47}, {-15, -15}, {9, 9}, {-9, -9},
                                   {25, 31}, {12, 15}, {-10, -15}};
    static const int strategies[] = {Z_DEFAULT_STRATEGY, Z_FILTERED, Z_HUFFMAN_ONLY, Z_RLE, Z_FIXED};
    static const size_t steps[][2] = {{1, 1}, {7, 13}, {100, 3}, {4096, 4096}, {65536, 1000}, {300000, 300000}};
    live_blocks = 0;
    int k = 0;
    for (int kind = 0; kind < KINDS; kind++) {
        fill(src, n, kind);
        for (int level = 0; level <= 9; level++) {
            for (size_t w = 0; w < sizeof wbits / sizeof *wbits; w++) {
                int strategy = strategies[k % 5], mem = 1 + k % 9;
                const size_t *st = steps[k % 6];
                size_t len = st[0] == 1 ? 3000 : n; /* byte by byte only for the start */
                k++;
                check(stream(src, len, level, wbits[w][0], mem, strategy, wbits[w][1], st[0], st[1], z, n * 2 + 1000,
                             back),
                      "stream %s level %d windowBits %d/%d memLevel %d strategy %d steps %zu/%zu", kind_name[kind],
                      level, wbits[w][0], wbits[w][1], mem, strategy, st[0], st[1]);
            }
        }
    }
    check(live_blocks == 0, "every block zalloc gave was given back (%ld left)", live_blocks);
    say("# %d streams, %ld blocks from zalloc\n", k, all_blocks);
    free(src);
    free(z);
    free(back);
    group("deflate / inflate streams: levels 0-9, zlib, gzip, raw, auto, small windows, strategies, flushes", f0, p0);
}

static int deflate_one(const unsigned char *src, size_t n, unsigned char *out, size_t cap, int level, int wbits,
                       int mem, int strategy, size_t *outlen) {
    z_stream s;
    memset(&s, 0, sizeof s);
    if (deflateInit2(&s, level, Z_DEFLATED, wbits, mem, strategy) != Z_OK) return 0;
    s.next_in = (Bytef *)src;
    s.avail_in = (uInt)n;
    s.next_out = out;
    s.avail_out = (uInt)cap;
    int rc = deflate(&s, Z_FINISH);
    *outlen = s.total_out;
    deflateEnd(&s);
    return rc == Z_STREAM_END;
}

/* Deflated files this computer's zlib must make byte for byte the same */
static void for_the_host(void) {
    int f0 = failed, p0 = passed;
    size_t n = 200000, len;
    unsigned char *text = malloc(n), *rand_ = malloc(n), *out = malloc(n * 2);
    seed = 777;
    fill(text, n, TEXT);
    fill(rand_, n, RANDOM);
    check(write_file("TEXT.DAT", text, n) && write_file("RAND.DAT", rand_, n), "data files written");
    FILE *m = fopen(path("MANIFEST.TXT"), "w");
    if (!check(m != NULL, "MANIFEST.TXT")) return;
    fprintf(m, "CRC TEXT.DAT %lu %lu\nCRC RAND.DAT %lu %lu\n", crc32(0, text, (uInt)n), adler32(1, text, (uInt)n),
            crc32(0, rand_, (uInt)n), adler32(1, rand_, (uInt)n));
    static const int wb[] = {15, 31, -15, 9, -12};
    static const int strategies[] = {Z_DEFAULT_STRATEGY, Z_FILTERED, Z_HUFFMAN_ONLY, Z_RLE, Z_FIXED};
    int i = 0;
    for (int level = 0; level <= 9; level++) {
        for (size_t w = 0; w < sizeof wb / sizeof *wb; w++) {
            for (int which = 0; which < 2; which++) {
                int mem = level == 4 ? 4 : level == 7 ? 9 : 8, strategy = level == 6 ? strategies[w] : 0;
                char name[16];
                snprintf(name, sizeof name, "D%03d.BIN", i++);
                int ok = deflate_one(which ? rand_ : text, n, out, n * 2, level, wb[w], mem, strategy, &len) &&
                         write_file(name, out, len);
                check(ok, "%s", name);
                fprintf(m, "DEF %s %s %d %d %d %d\n", name, which ? "RAND.DAT" : "TEXT.DAT", level, wb[w], mem,
                        strategy);
            }
        }
    }
    /* compress() and compress2() too */
    uLongf clen = n * 2;
    compress(out, &clen, text, n);
    write_file("COMPRESS.BIN", out, clen);
    fprintf(m, "COMPRESS COMPRESS.BIN TEXT.DAT\n");
    check(fclose(m) == 0, "MANIFEST.TXT written");
    say("# %d deflated files for the host\n", i);
    free(text);
    free(rand_);
    free(out);
    group("deflated files written for this computer's zlib", f0, p0);
}

/* Files this computer made: gzip, zlib and raw streams */
static void known_files(void) {
    int f0 = failed, p0 = passed;
    size_t tn, n;
    unsigned char *txt = read_file("KNOWN.TXT", &tn);
    if (!check(txt != NULL, "KNOWN.TXT there")) return;
    static const char *names[] = {"KNOWN.GZ", "GZIP9.GZ", "KNOWN.ZZ", "KNOWN.RAW", "MULTI.GZ"};
    static const int wbits[] = {31, 47, 15, -15, 31};
    unsigned char *back = malloc(tn + 16);
    for (int i = 0; i < 5; i++) {
        unsigned char *z = read_file(names[i], &n);
        if (!check(z != NULL, "%s there", names[i])) continue;
        z_stream s;
        memset(&s, 0, sizeof s);
        inflateInit2(&s, wbits[i]);
        s.next_in = z;
        s.avail_in = (uInt)n;
        s.next_out = back;
        s.avail_out = (uInt)tn + 16;
        int rc;
        /* MULTI.GZ: two members, inflateReset between them */
        while ((rc = inflate(&s, Z_NO_FLUSH)) == Z_STREAM_END && s.avail_in > 0) inflateReset(&s);
        check((rc == Z_STREAM_END || rc == Z_OK) && s.total_out <= tn && (size_t)(s.next_out - back) == tn &&
                  memcmp(back, txt, tn) == 0,
              "inflate %s: %d", names[i], rc);
        inflateEnd(&s);
        if (i != 2 && i != 3) {
            gzFile g = gzopen(path(names[i]), "rb");
            int got = g ? gzread(g, back, (unsigned)tn + 16) : -1;
            check(got == (int)tn && memcmp(back, txt, tn) == 0, "gzread %s: %d", names[i], got);
            if (g) gzclose(g);
        }
        free(z);
    }
    /* A gzip header's fields */
    unsigned char *z = read_file("KNOWN.GZ", &n);
    if (z) {
        z_stream s;
        gz_header h;
        unsigned char nm[64];
        memset(&s, 0, sizeof s);
        memset(&h, 0, sizeof h);
        h.name = nm;
        h.name_max = sizeof nm;
        inflateInit2(&s, 31);
        inflateGetHeader(&s, &h);
        s.next_in = z;
        s.avail_in = (uInt)n;
        s.next_out = back;
        s.avail_out = (uInt)tn;
        inflate(&s, Z_FINISH);
        check(h.done == 1 && strcmp((char *)nm, "known.txt") == 0 && h.time == 1700000000, "gzip header: %s %lu",
              h.name ? (char *)nm : "-", h.time);
        inflateEnd(&s);
        free(z);
    }
    free(back);
    free(txt);
    group("inflate and gzread of files made by this computer (gzip, gzip -9, zlib, raw, two members)", f0, p0);
}

static void gz_files(void) {
    int f0 = failed, p0 = passed;
    size_t n = 120000;
    seed = 4242;
    unsigned char *text = malloc(n), *back = malloc(n + 100);
    fill(text, n, TEXT);
    /* What OUT.GZ holds, as OUT.TXT, for the host */
    gzFile g = gzopen(path("OUT.GZ"), "wb9");
    check(g != NULL, "gzopen wb9");
    if (!g) return;
    check(gzbuffer(g, 4096) == 0, "gzbuffer");
    size_t at = 0;
    int ok = 1;
    while (at < n) {
        unsigned step = 1 + rnd() % 5000;
        if (step > n - at) step = (unsigned)(n - at);
        ok &= gzwrite(g, text + at, step) == (int)step;
        at += step;
    }
    check(ok, "gzwrite in pieces");
    check(gzprintf(g, "\nline %d of %s\n", 42, "gzprintf") > 0, "gzprintf");
    check(gzputs(g, "gzputs line\n") > 0, "gzputs");
    check(gzputc(g, 'Z') == 'Z' && gzputc(g, '\n') == '\n', "gzputc");
    check(gzflush(g, Z_SYNC_FLUSH) == Z_OK, "gzflush");
    check(gzsetparams(g, 1, Z_DEFAULT_STRATEGY) == Z_OK, "gzsetparams");
    check(gzfwrite("tail\n", 1, 5, g) == 5, "gzfwrite");
    check(gzclose(g) == Z_OK, "gzclose (write)");
    const char tail[] = "\nline 42 of gzprintf\ngzputs line\nZ\ntail\n";
    size_t total = n + sizeof tail - 1;
    unsigned char *all = malloc(total);
    memcpy(all, text, n);
    memcpy(all + n, tail, sizeof tail - 1);
    write_file("OUT.TXT", all, total);

    g = gzopen(path("OUT.GZ"), "rb");
    check(g != NULL && gzdirect(g) == 0, "gzopen rb, gzdirect 0");
    unsigned char *rd = malloc(total + 10);
    int got = gzread(g, rd, (unsigned)total + 10);
    check(got == (int)total && memcmp(rd, all, total) == 0, "gzread all back: %d of %zu", got, total);
    check(gzeof(g) == 1, "gzeof");
    check(gzrewind(g) == 0 && gztell(g) == 0, "gzrewind, gztell");
    check(gzseek(g, 1000, SEEK_SET) == 1000 && gzgetc(g) == all[1000] && gztell(g) == 1001, "gzseek, gzgetc");
    check(gzungetc('#', g) == '#' && gzgetc(g) == '#' && gzgetc_(g) == all[1001], "gzungetc, gzgetc_");
    check(gzseek(g, 50, SEEK_CUR) == 1052 && gzgetc(g) == all[1052], "gzseek SEEK_CUR");
    gzrewind(g);
    char line[8192];
    long lines = 0;
    size_t len = 0;
    while (gzgets(g, line, sizeof line)) {
        lines++;
        len += strlen(line);
    }
    long want = 0;
    for (size_t i = 0; i < total; i++) want += all[i] == '\n';
    check(len == total && lines == want, "gzgets: %ld lines, %zu bytes", lines, len);
    check(gzoffset(g) > 0, "gzoffset");
    check(gzclose_r(g) == Z_OK, "gzclose_r");

    /* Appending makes a second member; reading goes on through it */
    g = gzopen(path("APPEND.GZ"), "wb");
    gzwrite(g, "first member\n", 13);
    gzclose_w(g);
    g = gzopen(path("APPEND.GZ"), "ab1");
    check(g != NULL, "gzopen ab");
    gzwrite(g, "second member\n", 14);
    gzclose(g);
    g = gzopen(path("APPEND.GZ"), "rb");
    got = gzread(g, rd, 100);
    check(got == 27 && memcmp(rd, "first member\nsecond member\n", 27) == 0, "two members read as one: %d", got);
    gzclose(g);

    /* Transparent: written plain, read plain */
    g = gzopen(path("PLAIN.TXT"), "wT");
    gzwrite(g, "plain text\n", 11);
    gzclose(g);
    size_t pn;
    unsigned char *p = read_file("PLAIN.TXT", &pn);
    check(p && pn == 11 && memcmp(p, "plain text\n", 11) == 0, "gzopen wT writes plain");
    free(p);
    g = gzopen(path("PLAIN.TXT"), "rb");
    got = gzread(g, rd, 100);
    check(gzdirect(g) == 1 && got == 11, "a plain file through gzread (gzdirect 1)");
    gzclose(g);

    /* gzfread, errors */
    g = gzopen(path("OUT.GZ"), "rb");
    check(g && gzfread(rd, 10, 100, g) == 100 && memcmp(rd, all, 1000) == 0 && gztell(g) == 1000, "gzfread");
    gzclose(g);
    check(gzopen(path("NOSUCH.GZ"), "rb") == NULL, "gzopen of a missing file fails");
    g = gzopen(path("TEXT.DAT"), "rb"); /* not gzip: read as it is */
    check(g && gzread(g, rd, 10) == 10 && gzdirect(g), "a non-gzip file reads plain");
    gzclose(g);
    size_t bn;
    unsigned char *bad = read_file("KNOWN.GZ", &bn); /* its CRC damaged */
    if (bad) {
        bad[bn - 6] ^= 1;
        write_file("BAD.GZ", bad, bn);
        free(bad);
    }
    g = gzopen(path("BAD.GZ"), "rb");
    int err = 0;
    while (g && gzread(g, rd, (unsigned)total) > 0) continue;
    const char *msg = g ? gzerror(g, &err) : "";
    check(g && err == Z_DATA_ERROR && msg && strstr(msg, "incorrect data check"), "gzerror on a damaged file: %d %s",
          err, msg);
    if (g) {
        gzclearerr(g);
        gzclose(g);
    }
    free(rd);
    free(all);
    free(text);
    free(back);
    group("gz files: gzopen, gzwrite, gzprintf, gzputs, gzread, gzgets, gzseek, append, transparent, errors", f0, p0);
}

static void more_api(void) {
    int f0 = failed, p0 = passed;
    size_t n = 50000;
    seed = 99;
    unsigned char *src = malloc(n), *z = malloc(n * 2), *back = malloc(n + 1);
    fill(src, n, TEXT);
    const char dict[] = "the quick brown fox jumps over lazy dog compression library";
    z_stream s;

    /* Dictionaries */
    memset(&s, 0, sizeof s);
    deflateInit(&s, 9);
    check(deflateSetDictionary(&s, (const Bytef *)dict, sizeof dict - 1) == Z_OK, "deflateSetDictionary");
    unsigned char got_dict[64];
    uInt dlen = sizeof got_dict;
    check(deflateGetDictionary(&s, got_dict, &dlen) == Z_OK && dlen == sizeof dict - 1, "deflateGetDictionary");
    s.next_in = src;
    s.avail_in = (uInt)n;
    s.next_out = z;
    s.avail_out = (uInt)n * 2;
    deflate(&s, Z_FINISH);
    size_t zn = s.total_out;
    uLong id = s.adler;
    deflateEnd(&s);
    memset(&s, 0, sizeof s);
    inflateInit(&s);
    s.next_in = z;
    s.avail_in = (uInt)zn;
    s.next_out = back;
    s.avail_out = (uInt)n;
    int rc = inflate(&s, Z_FINISH);
    check(rc == Z_NEED_DICT && s.adler == adler32(1, (const Bytef *)dict, sizeof dict - 1), "Z_NEED_DICT");
    check(inflateSetDictionary(&s, (const Bytef *)dict, sizeof dict - 1) == Z_OK, "inflateSetDictionary");
    rc = inflate(&s, Z_FINISH);
    check(rc == Z_STREAM_END && s.total_out == n && memcmp(src, back, n) == 0, "inflate with the dictionary");
    (void)id;
    inflateEnd(&s);

    /* deflateParams mid-stream, deflateCopy, Bound, Pending, Tune, Prime: */
    memset(&s, 0, sizeof s);
    deflateInit(&s, 1);
    check(deflateTune(&s, 8, 16, 32, 64) == Z_OK, "deflateTune");
    s.next_in = src;
    s.avail_in = (uInt)n / 2;
    s.next_out = z;
    s.avail_out = (uInt)n * 2;
    deflate(&s, Z_NO_FLUSH);
    check(deflateParams(&s, 9, Z_FILTERED) == Z_OK, "deflateParams");
    unsigned pend;
    int bits;
    check(deflatePending(&s, &pend, &bits) == Z_OK, "deflatePending");
    z_stream c;
    check(deflateCopy(&c, &s) == Z_OK, "deflateCopy");
    unsigned char *z2 = malloc(n * 2);
    size_t before = s.next_out - z;
    memcpy(z2, z, before);
    s.next_in = src + n / 2;
    s.avail_in = (uInt)(n - n / 2);
    deflate(&s, Z_FINISH);
    c.next_out = z2 + before;
    c.avail_out = (uInt)(n * 2 - before);
    c.next_in = src + n / 2;
    c.avail_in = (uInt)(n - n / 2);
    deflate(&c, Z_FINISH);
    check(s.total_out == c.total_out && memcmp(z, z2, s.total_out) == 0, "the copy deflates the same");
    check(deflateBound(&s, n) >= s.total_out && deflateBound_z(&s, n) >= s.total_out, "deflateBound");
    zn = s.total_out;
    deflateEnd(&s);
    deflateEnd(&c);
    uLongf bl = n + 1;
    check(uncompress(back, &bl, z, zn) == Z_OK && bl == n && memcmp(back, src, n) == 0, "params changed mid-stream");

    /* inflateCopy, inflateSync after a full flush, inflateMark */
    memset(&s, 0, sizeof s);
    deflateInit(&s, 6);
    s.next_in = src;
    s.avail_in = (uInt)n / 2;
    s.next_out = z;
    s.avail_out = (uInt)n * 2;
    deflate(&s, Z_FULL_FLUSH);
    size_t cut = s.total_out;
    s.next_in = src + n / 2;
    s.avail_in = (uInt)(n - n / 2);
    deflate(&s, Z_FINISH);
    zn = s.total_out;
    deflateEnd(&s);
    memset(&s, 0, sizeof s);
    inflateInit2(&s, -15);
    s.next_in = z + 102; /* a damaged start: the header and 100 bytes missing */
    s.avail_in = (uInt)(cut - 102);
    s.next_out = back;
    s.avail_out = (uInt)n;
    inflate(&s, Z_NO_FLUSH);
    s.next_in = z + 102;
    s.avail_in = (uInt)(zn - 102);
    rc = inflateSync(&s);
    check(rc == Z_OK && s.next_in == z + cut, "inflateSync finds the full flush point");
    s.next_out = back;
    s.avail_out = (uInt)n;
    z_stream ic;
    check(inflateCopy(&ic, &s) == Z_OK, "inflateCopy");
    inflate(&s, Z_SYNC_FLUSH);
    check(memcmp(back, src + n / 2, (n - n / 2) - 8) == 0, "inflate after inflateSync");
    inflateEnd(&s);
    inflateEnd(&ic);

    /* Errors */
    uLongf small = 10;
    check(compress(z, &small, src, n) == Z_BUF_ERROR, "compress into too little: Z_BUF_ERROR");
    uLongf zl = n * 2;
    compress(z, &zl, src, n);
    z[zl / 2] ^= 0x55;
    bl = n + 1;
    rc = uncompress(back, &bl, z, zl);
    check(rc == Z_DATA_ERROR, "damaged data: Z_DATA_ERROR (%d)", rc);
    z[zl / 2] ^= 0x55;
    bl = n - 1;
    check(uncompress(back, &bl, z, zl) == Z_BUF_ERROR, "uncompress into too little: Z_BUF_ERROR");
    bl = n + 1;
    check(uncompress(back, &bl, z, zl - 3) == Z_DATA_ERROR, "truncated input: Z_DATA_ERROR");
    memset(&s, 0, sizeof s);
    inflateInit(&s);
    s.next_in = (Bytef *)"\x78\x9c\xff\xff\xff";
    s.avail_in = 5;
    s.next_out = back;
    s.avail_out = 100;
    rc = inflate(&s, Z_FINISH);
    check(rc == Z_DATA_ERROR && s.msg != NULL, "garbage: Z_DATA_ERROR, msg \"%s\"", s.msg ? s.msg : "");
    inflateEnd(&s);
    check(deflateInit(&s, 12) == Z_STREAM_ERROR, "level 12: Z_STREAM_ERROR");
    free(z2);
    free(src);
    free(z);
    free(back);
    group("dictionaries, deflateParams, deflateCopy, inflateSync, inflateCopy, errors", f0, p0);
}

/* inflateBack: callbacks over the input and output */
static unsigned char *ib_src;
static size_t ib_len, ib_out;
static unsigned char *ib_dst;
static unsigned ib_in(void *d, z_const unsigned char **buf) {
    (void)d;
    *buf = ib_src;
    size_t n = ib_len < 999 ? ib_len : 999;
    ib_src += n;
    ib_len -= n;
    return (unsigned)n;
}
static int ib_put(void *d, unsigned char *buf, unsigned len) {
    (void)d;
    memcpy(ib_dst + ib_out, buf, len);
    ib_out += len;
    return 0;
}

static void inflate_back(void) {
    int f0 = failed, p0 = passed;
    size_t n = 100000, zn;
    seed = 5;
    unsigned char *src = malloc(n), *z = malloc(n * 2), *back = malloc(n);
    fill(src, n, TEXT);
    deflate_one(src, n, z, n * 2, 6, -15, 8, 0, &zn);
    unsigned char *window = malloc(32768);
    z_stream s;
    memset(&s, 0, sizeof s);
    check(inflateBackInit(&s, 15, window) == Z_OK, "inflateBackInit");
    ib_src = z;
    ib_len = zn;
    ib_dst = back;
    ib_out = 0;
    int rc = inflateBack(&s, ib_in, NULL, ib_put, NULL);
    check(rc == Z_STREAM_END && ib_out == n && memcmp(back, src, n) == 0, "inflateBack: %d", rc);
    check(inflateBackEnd(&s) == Z_OK, "inflateBackEnd");
    free(window);
    free(src);
    free(z);
    free(back);
    group("inflateBack", f0, p0);
}

static double now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static void speed(void) {
    size_t n = 4 << 20;
    seed = 1;
    unsigned char *src = malloc(n), *z = malloc(compressBound(n)), *back = malloc(n);
    fill(src, n, TEXT);
    for (int level = 1; level <= 9; level += 5) {
        uLongf zl = compressBound(n), bl = n;
        double t0 = now();
        compress2(z, &zl, src, n, level);
        double t1 = now();
        uncompress(back, &bl, z, zl);
        double t2 = now();
        say("# speed level %d: 4 MiB text -> %lu bytes, deflate %.1f MB/s, inflate %.1f MB/s\n", level, zl,
            n / 1e6 / (t1 - t0 > 0 ? t1 - t0 : 1e-9), n / 1e6 / (t2 - t1 > 0 ? t2 - t1 : 1e-9));
    }
    double t0 = now();
    uLong c = crc32(0, src, (uInt)n);
    double t1 = now();
    say("# speed crc32 %.0f MB/s (%08lx)\n", n / 1e6 / (t1 - t0 > 0 ? t1 - t0 : 1e-9), c);
    free(src);
    free(z);
    free(back);
}

int main(void) {
    zdos_drive_info info;
    for (uint32_t i = 0; zdos->drives->at(i, &info); i++) {
        if (info.ready && info.letter && info.label_len == 6 && strncasecmp(info.label, "ZLDISK", 6) == 0) {
            dir[0] = (char)info.letter;
        }
    }
    if (dir[0] == '?') {
        printf("ZLIBTEST: no drive labelled ZLDISK\n");
        return 1;
    }
    snprintf(log_path, sizeof log_path, "%sZLIBTEST.LOG", dir);
    remove(log_path);
    versions();
    checksums();
    round_trips();
    streams();
    for_the_host();
    known_files();
    gz_files();
    more_api();
    inflate_back();
    speed();
    say("# ZLIBTEST: %d passed, %d failed\n", passed, failed);
    return failed;
}
