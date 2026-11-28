# YEncTest (test build only, fork)

Never part of a PR. For the test app only: measures Nuvio's yEnc decoder and CRC32
(`UsenetYEnc`, `UsenetCRC32`) against node-yencode on the articles a Usenet stream reads, and
writes the results to Settings → Usenet → Test Log (lines starting with `yenc-test:`).

- `common.h`, `hedley.h`, `platform.cc`, `decoder*.{h,cc}`, `crc*.{h,cc}`: unchanged from
  [animetosho/node-yencode](https://github.com/animetosho/node-yencode) at
  `836ed11f8e079e43ca1980bf8de1e48afe2b4fc1`, Public Domain / CC0. Only the files the ARM64
  decoder (NEON) and CRC32 (ARMv8 CRC, PMULL) need.
- `NuvioYEncTest.{h,cc}`: the C entry points Swift calls (through the bridging header), and
  zlib's CRC32 for comparison.
- `Core/Usenet/UsenetYEncBench.swift`: the measurement and its log lines.
