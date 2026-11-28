// Test build only (fork), never part of a PR: the C entry points of NuvioYEncTest.h over
// node-yencode (https://github.com/animetosho/node-yencode, CC0) and zlib.

#include "NuvioYEncTest.h"

#include <mutex>
#include <string.h>
#include <zlib.h>

#include "crc.h"
#include "decoder.h"

void nuvio_yenc_test_init(void) {
    static std::once_flag once;
    std::call_once(once, [] {
        RapidYenc::decoder_init();
        RapidYenc::crc32_init();
    });
}

int nuvio_yenc_test_decoder_isa(void) {
    return RapidYenc::decode_isa_level();
}

int nuvio_yenc_test_crc_isa(void) {
    return RapidYenc::crc32_isa_level();
}

size_t nuvio_yenc_test_decode(const uint8_t *body, size_t length, uint8_t *out) {
    // The data starts after the =ybegin line and, for a part, the =ypart line.
    size_t start = 0;
    while (start + 2 <= length && body[start] == '=' && body[start + 1] == 'y') {
        if (length - start >= 5 && memcmp(body + start, "=yend", 5) == 0) return 0;
        const void *newline = memchr(body + start, '\n', length - start);
        if (!newline) return 0;
        start = (size_t)((const uint8_t *)newline - body) + 1;
    }
    if (start >= length) return 0;
    // Raw decoding: undoes the NNTP dot stuffing and stops at the "\r\n=y" of the =yend line.
    const void *src = body + start;
    void *dst = out;
    RapidYenc::YencDecoderState state = RapidYenc::YDEC_STATE_CRLF;
    RapidYenc::decode_end(&src, &dst, length - start, &state);
    return (size_t)((uint8_t *)dst - out);
}

uint32_t nuvio_yenc_test_crc32(const uint8_t *data, size_t length) {
    return RapidYenc::crc32(data, length, 0);
}

uint32_t nuvio_yenc_test_zlib_crc32(const uint8_t *data, size_t length) {
    uLong crc = crc32(0L, Z_NULL, 0);
    while (length > 0) {
        uInt chunk = length > 0x40000000 ? 0x40000000 : (uInt)length;
        crc = crc32(crc, data, chunk);
        data += chunk;
        length -= chunk;
    }
    return (uint32_t)crc;
}
