#define XXH_INLINE_ALL
#include "xxhash.h"
#include "zstd/zstd.h"
#include "csupport.h"

uint64_t sl_xxh64(const void *data, size_t len) { return XXH64(data, len, 0); }

size_t sl_zstd_decompress(void *dst, size_t dst_cap, const void *src, size_t src_size) {
    size_t const n = ZSTD_decompress(dst, dst_cap, src, src_size);
    return ZSTD_isError(n) ? SIZE_MAX : n;
}

#include <stdlib.h>
#include <zlib.h>

void *sl_zstd_decompress_all(const void *src, size_t src_size, size_t *out_size) {
    ZSTD_DStream *ds = ZSTD_createDStream();
    if (!ds) return NULL;
    size_t cap = src_size * 3 + 4096, len = 0;
    char *dst = malloc(cap);
    ZSTD_inBuffer in = { src, src_size, 0 };
    while (dst) {
        if (len == cap) {
            char *bigger = realloc(dst, cap * 2);
            if (!bigger) { free(dst); dst = NULL; break; }
            dst = bigger; cap *= 2;
        }
        ZSTD_outBuffer out = { dst + len, cap - len, 0 };
        size_t r = ZSTD_decompressStream(ds, &out, &in);
        if (ZSTD_isError(r)) { free(dst); dst = NULL; break; }
        len += out.pos;
        if (in.pos == in.size && out.pos < out.size) break;     // all input read and nothing more to flush
    }
    ZSTD_freeDStream(ds);
    *out_size = len;
    return dst;
}

void *sl_gzip_decompress_all(const void *src, size_t src_size, size_t *out_size) {
    z_stream z = {0};
    if (inflateInit2(&z, 16 + MAX_WBITS) != Z_OK) return NULL;
    size_t cap = src_size * 3 + 4096, len = 0;
    char *dst = malloc(cap);
    z.next_in = (Bytef *)src;
    z.avail_in = (uInt)src_size;
    int r = Z_OK;
    while (dst && r != Z_STREAM_END) {
        if (len == cap) {
            char *bigger = realloc(dst, cap * 2);
            if (!bigger) { free(dst); dst = NULL; break; }
            dst = bigger; cap *= 2;
        }
        size_t room = cap - len > 0x40000000 ? 0x40000000 : cap - len;
        z.next_out = (Bytef *)(dst + len);
        z.avail_out = (uInt)room;
        r = inflate(&z, Z_NO_FLUSH);
        len += room - z.avail_out;
        if (r != Z_OK && r != Z_STREAM_END) { free(dst); dst = NULL; break; }
        if (r == Z_OK && z.avail_in == 0 && z.avail_out != 0) break;
    }
    inflateEnd(&z);
    *out_size = len;
    return dst;
}
