# EW3270U protocol investigation

Hardware: BenQ EW3270U / BNQ7950, display UUID
`57CF2C6E-B43C-8507-0857-D6964E3302DB`.

## Evidence and limits

This investigation uses DDC/CI requests over macOS IOAVService. No monitor
firmware image or firmware source code has been obtained or modified.
Reading a firmware binary, if one becomes available, would require reverse
engineering; it is not equivalent to obtaining the original source code.

Some unsupported queries return the previous feature's payload while echoing
the newly requested feature code and a valid checksum. Consequently, an
unfiltered register scan produces misleading results. The helper primes each
read with controller identity `0xC8`, then rejects its repeated payload.

The public [EW3270U report in ddccontrol-db](https://github.com/ddccontrol/ddccontrol-db/issues/244)
also contains long runs of repeated values. Its conservative monitor profile
does not supply a verified complete picture-mode mapping.
[BenQ specifications](https://www.benq.com/en-ph/monitor/home/ew3270u/spec.html)
list both sRGB and Rec.709, but do not document their DDC encoding.

## Picture mode readbacks (VCP 0xDC)

| Physical menu selection | Decimal readback | Evidence |
| --- | ---: | --- |
| 标准 | 0 | Earlier session observation; physical selection after software write still needs final verification |
| 游戏 | 5 | Earlier user-selected mode and immediate readback |
| 图片 | 11 | Explicit user confirmation and repeated live reads |
| sRGB | 12 | Explicit user confirmation and repeated live reads |
| Rec.709 | 12 | User reports this mode; main readback equals sRGB; independent control unresolved |
| 省电 | 14 | Explicit individual user confirmation and repeated reads |
| M-book | 15 | Explicit individual user confirmation and repeated reads |
| 用户 | 18 | Explicit individual user confirmation and repeated reads |
| 低蓝光 / 多媒体 | 275 | Earlier read/write verification |
| 低蓝光 / 网上冲浪 | 531 | Physical menu and repeated read/write observations |
| 低蓝光 / 办公室 | 787 | Earlier read/write verification |
| 低蓝光 / 阅读 | 1043 | Earlier read/write verification |
| 影院 HDR | 255 | User-selected mode; writing 255 did not establish a working switch |

Readback correspondence is not proof that writing a value selects the intended
OSD mode. In particular, 12 must not be presented as two independently verified
sRGB and Rec.709 actions. Earlier verbal inferences sRGB=11 and Rec.709=12 based
only on sequence order were withdrawn; the table uses individual observations.

Evidence is retained in `build/mode-capture-debug.jsonl`,
`build/mode-capture.jsonl`, and `build/mode-confirmations.jsonl`.
The sampler targets four reads per second; bus delays/retries reduce the
achieved frequency, especially during physical mode changes.

## Differential snapshot procedure

`scripts/read-registers.m` sends only Get VCP requests to the exact display UUID.
It reads picture mode, picture parameters, and vendor codes 0xE0–0xFF with an
identity sentinel before every query. No Set VCP or firmware commands are used.
It records the raw frames, transport results, and mode at both endpoints.

Compile with:

```sh
xcrun clang -O2 -Wall -Wextra -Werror -fmodules -arch arm64 -mmacosx-version-min=13.0 -I Vendor/m1ddc -framework CoreDisplay Vendor/m1ddc/ioregistry.m scripts/read-registers.m -o .build.noindex/read-registers
```

After the user confirms a mode and holds it, run:

```sh
python3 scripts/capture-registers.py rec709
```

The wrapper pauses the existing fast sampler, takes two snapshots (about 45
seconds), and resumes it in a finally block. The user then selects sRGB once,
and the same command with label `srgb` supplies the comparison. Compare stable,
checksum-valid, non-sentinel replies across both modes. A difference is only a
candidate discriminator, not permission to write an unknown vendor register.
Equal endpoint modes do not prove no change occurred between them, and cannot
detect a switch between two modes that share the same readback.

### sRGB / Rec.709 differential result

User-confirmed stationary selections were captured twice each:
`20261024-085946-rec709` and `20261024-090123-srgb` under
`build/protocol-snapshots`. All fresh replies were stable between repetitions.
The comparison is saved in `build/protocol-snapshots/srgb-vs-rec709.json`.

| VCP | Rec.709 current / reported max | sRGB current / reported max |
| --- | --- | --- |
| 0xDC picture mode | 12 / 1043 | 12 / 1043 |
| 0x14 color preset | 11 / 11 | 12 / 11 |
| 0x10 brightness | 18 / 100 | 100 / 100 |

The initial 0x14 discriminator hypothesis was **disproved** by a subsequent
read-order experiment with no Set VCP commands. In the same physical mode:

1. Read aspect ratio 0x86=5, then 0x14 returns 5 (maximum 11).
2. Read picture mode 0xDC=12, then 0x14 returns 12 (maximum 11).
3. Read aspect ratio again, then 0x14 returns 5 again.

Raw evidence: `build/protocol-snapshots/color-aspect-order.txt`.
This is partial stale data: the maximum is specific to 0x14, while the current
value is copied from a preceding discrete query. The original full-payload
sentinel check alone does not detect it. The proposed parser exception was
removed and 0x14 is not exposed as a product control. The earlier statement
that 0x14 distinguished sRGB/Rec.709 was withdrawn explicitly to the user.

Brightness is an actual writable control in the later tested mode, but saved
brightness differences must not be used as mode identifiers. Contrast reads
50 but a target of 49 failed both the helper and fresh-process readback; the
original 50 was retained. Contrast has been removed from the UI as requested.

## Verified product controls and write settlement

The real monitor accepted all exposed mode values, sharpness 4/6, and AMA 0/2;
settings were restored. Evidence: `build/settings-verification.json`.
Aspect ratio writes apply but can leave the initiating process unable to read
back the display, even after service rediscovery. The helper reports a
`writeSent` error rather than claiming rejection or success. DDCClient then
opens up to four bounded, new read-only helper processes and requires the
requested value to match. It never resends the write. The actual DDCClient
passed targets 5, 1, 2; the display is restored to the original full setting 2.

Current implementation exposes standard, game, photo, grouped sRGB/Rec.709,
eco, M-book, user, and four low-blue-light modes. It does not expose speculative
mode numbers from unrelated BenQ models. HDR/B.I.+ remain physical-menu
controls, since no reliable writable mapping has been established.

The first attempted Rec.709 baseline actually returned 531 at both endpoints
in both passes. It was relabeled `web-baseline-1/2` under
`build/protocol-snapshots`; it must not be used as Rec.709 evidence.

If differential reads do not expose a reliable discriminator, investigate a
documented compatible vendor application's commands or model-specific protocol
documentation. Firmware analysis is a later option requiring an exact-model
image; repeated mode-code guesses cannot establish support.

## Menu structure versus independent controls

User photos IMG_7384/7385/7386 and the subsequent correction establish two
separate OSD menus: Picture Mode and Low Blue Light. The low-blue menu remains
accessible across picture modes. Version 1.2.2 mirrors those peer menus.
The four verified low-blue scene actions currently write VCP 0xDC. There is
no verified separate register or combined encoding that preserves another
picture mode while changing its low-blue scene. Do not infer parameter
independence from menu accessibility, or infer a parent/child menu hierarchy
from the combined readback. A non-low-blue readback does not establish the
current stored low-blue scene; cached scene values are not live hardware state.

The official [E Series manual including EW3270U](https://esupportdownload.benq.com/esupport/LCD%20MONITOR/UserManual/EL2870U/UM_EN_210210082801.pdf),
printed pages 35–36 and 40–41, documents a separate Eye Care / Low Blue Light
menu and a Low Blue Light picture-mode entry referring to its four scenarios.
This supports the two-entry UI, but does not document independent combinations
or any separate DDC command. It is not evidence of game-plus-reading support.

## Vendor software investigation (2026-10-24)

[Display Pilot 2 compatibility](https://www.benq.com/en-sg/monitor/software/display-pilot-2/spec.html)
and [Display Pilot compatibility](https://www.benq.com/en-in/monitor/software/display-pilot/spec.html)
do not list EW3270U. They are not established sources of this model’s commands.
The official software-download page did not yield a firmware image; its dynamic
placeholders do not prove that no firmware exists. A generic online BenQ mode
table targets other models and conflicts with our observed sRGB value; none of
its additional commands were adopted or sent. Findings and URLs are saved in
`build/vendor-protocol-research.json`.

A focused user question is pending: after selecting Reading from the physical
low-blue menu while in Game, does the physical Picture Mode still show Game,
or change to Low Blue Light? This establishes the OSD semantics without
requiring another full mode cycle. It is not yet evidence of a separate DDC
register, even if both settings coexist.
