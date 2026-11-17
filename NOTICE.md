# Third-party code and references

## Vendored

**PlayFair** (`Sources/CFairPlay/playfair/`): by EstebanKubata, GNU GPL. Copied unchanged from
[UxPlay](https://github.com/FDH2/UxPlay) `lib/playfair` at commit
`d4b7373cb6107b2d8d6c5838991c19d39e2b96ae`. It is a reverse-engineered implementation of
Apple's FairPlay SAP handshake. UxPlay describes its legal status as unclear.

**FairPlay reply tables** (`Sources/CFairPlay/fairplay.c`): the `reply_message` and `fp_header`
tables come from UxPlay's `lib/fairplay_playfair.c`, Copyright (C) 2018 Juho Vähä-Herttua,
GNU LGPL v2.1 or later. The surrounding functions are new. They also check the mode byte that
PlayFair uses as an unchecked table index.

## Used as a reference

The Swift protocol code was written using UxPlay (GNU GPL v3; most of its `lib/` derives from
ShairPlay and AirplayServer, GNU LGPL v2.1+) as a guide to the AirPlay mirroring protocol:
`raop_handlers.h`, `raop_rtp_mirror.c`, `mirror_buffer.c`, `pairing.c`, `raop_ntp.c`, `dnssd.c`.

## What this means

Porthole's builds include PlayFair, so the app as distributed (including the releases on this
repository) falls under the GPL's terms, with its source available here.
