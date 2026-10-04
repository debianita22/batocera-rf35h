#!/bin/bash
# ci-release-notes.sh - il testo di una release (lo usa build.yml).
#
#   tools/ci-release-notes.sh DIST VERSIONE
#
# DIST e' la cartella dei file della release (ci-build.sh collect).
set -euo pipefail

DIST="${1:?uso: ci-release-notes.sh DIST VERSIONE}"
VERSION="${2:?uso: ci-release-notes.sh DIST VERSIONE}"
O="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../batocera.pin
. "$O/batocera.pin"

IMG="$(cd "$DIST" && ls -- batocera-rk3326-rf35h-*.img.gz)"
size() { du -h "$DIST/$1" | cut -f1; }

cat <<EOF
Unofficial Batocera build for the **XiFan RF35H** (RK3326), ${VERSION}.

- Batocera: [\`${BATOCERA_COMMIT:0:7}\`](https://github.com/batocera-linux/batocera.linux/commit/${BATOCERA_COMMIT}) (v44 in development), with the patches in \`upstream/\` and \`fork/\` of this repository
- Version string on the console: \`$(cat "$DIST/batocera.version")\`
- Image check: $(tail -1 "$DIST/verify-image.txt")

## Files

| File | Size | Use |
|---|---|---|
| \`${IMG}\` | $(size "$IMG") | First install: write it to an SD card (it erases the card) |
| \`boot.tar.xz\` | $(size boot.tar.xz) | Update: the consoles download it from EmulationStation (Updates & downloads) |
| \`boot.tar.xz.md5\`, \`batocera.version\` | | Read by the update check |
| \`SHA256SUMS\` | | Checksums |
| \`verify-image.txt\` | | What \`tools/verify-image.sh\` checked in this image |

An update replaces the boot partition only: ROMs, saves and settings in the
SHARE partition stay. The loader at the start of the card is never rewritten.

This is not an official Batocera release and is not supported by the Batocera
team: report problems here.
EOF
