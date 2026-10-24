# Vendored DDC transport

`m1ddc/ioregistry.m`, `ioregistry.h`, and `utils.h` are unmodified files from
[waydabber/m1ddc](https://github.com/waydabber/m1ddc), commit
`04d949794102eb8df01ad3681afff6464a3eede2` (MIT).

The license is in `m1ddc/LICENSE` and is copied into the application bundle.
Only display discovery and IOAVService transport matching are used. Packet
encoding, validated reply parsing, bounded commands, locking, retries and
write verification are implemented in `Sources/DDCHelper`.

Apple Silicon DDC/CI requires private IOKit/CoreDisplay entry points. This
local macOS app is not sandboxed or submitted to the Mac App Store. Future
macOS changes may require updates. No third-party package is downloaded at
build time and the application makes no network requests.
