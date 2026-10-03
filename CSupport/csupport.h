#include <stddef.h>
#include <stdint.h>

/// XXH64 with seed 0 (League's WAD path hashes).
uint64_t sl_xxh64(const void *data, size_t len);

/// Decompresses one or more zstd frames. Returns the decompressed size, or SIZE_MAX on error.
size_t sl_zstd_decompress(void *dst, size_t dst_cap, const void *src, size_t src_size);

/// Decompresses a whole zstd stream whose size isn't known ahead (e.g. a compressed .blend). Returns a buffer to free(),
/// or NULL on error; its size goes to *out_size.
void *sl_zstd_decompress_all(const void *src, size_t src_size, size_t *out_size);

/// Same for a gzip stream.
void *sl_gzip_decompress_all(const void *src, size_t src_size, size_t *out_size);
