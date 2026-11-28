//
// NuvioYEncTest.h
// Test build only (fork), never part of a PR: node-yencode's yEnc decoder (NEON) and CRC32
// (ARMv8 CRC, PMULL), and the system zlib's CRC32, for UsenetYEncBench to measure against
// Nuvio's own decoder on the articles a stream reads.
//

#ifndef NuvioYEncTest_h
#define NuvioYEncTest_h

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Picks node-yencode's fastest decoder and CRC for this CPU. Call once before the rest.
void nuvio_yenc_test_init(void);

/// node-yencode's ISA levels: the decoder's (0 generic, 0x1000 NEON) and the CRC's
/// (0 generic, 8 ARMv8 CRC, | 0x40 PMULL).
int nuvio_yenc_test_decoder_isa(void);
int nuvio_yenc_test_crc_isa(void);

/// Decodes an article body as Nuvio gets it from the server (lines joined by CRLF, dots still
/// stuffed, its =ybegin, =ypart and =yend lines included) into `out`, which holds at least
/// `length` bytes. Returns the decoded length.
size_t nuvio_yenc_test_decode(const uint8_t *body, size_t length, uint8_t *out);

/// CRC32 (IEEE) of `data`: node-yencode's, and the system zlib's.
uint32_t nuvio_yenc_test_crc32(const uint8_t *data, size_t length);
uint32_t nuvio_yenc_test_zlib_crc32(const uint8_t *data, size_t length);

#ifdef __cplusplus
}
#endif

#endif /* NuvioYEncTest_h */
