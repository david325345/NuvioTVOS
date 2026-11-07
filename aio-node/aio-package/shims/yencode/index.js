'use strict';
function unavailable() {
  throw new Error('yEnc is not available on Apple TV: AIOStreams\' Usenet engine is off here (Nuvio Usenet plays Usenet streams).');
}
module.exports = { decodeTo: unavailable, decodeChunk: unavailable, crc32: unavailable, from_post: unavailable, decode: unavailable, encode: unavailable };
module.exports.default = module.exports;
