#!/bin/bash
# ci-check.sh - i controlli veloci, a ogni push (.github/workflows/check.yml) e
# prima di ogni build (build.yml): un errore qui costa minuti, dopo ore di
# build costerebbe la build.
#
#   tools/ci-check.sh [--tree DIR] [--work DIR] [--kernel-src DIR] [--quick]
#
#   1. script: bash -n e shellcheck (avvisi) su tools/*.sh; actionlint sui
#      workflow, se c'e'
#   2. loader: board/loader/known-good.bin e' quello di known-good.sha256
#   3. patch: tools/apply.sh su DIR (predefinita: WORK/batocera.linux), cioe'
#      Batocera al commit fissato + upstream/ + fork/, applicate senza fuzz
#   4. configurazione: il target rf35h di Batocera configurato con buildroot
#      (make batocera-rf35h_defconfig, poi show-info): le immagini, il DTB, i
#      pacchetti che devono esserci (rk915, rocknix-joypad, U-Boot mainline...)
#      e quelli che il profilo snello toglie (Kodi, MAME attuale, Moonlight)
#   5. kernel: tools/check-dtb.sh (DTB con W=1, joypad e rk915 compilati)
#   6. test: test-upgrade.sh (batocera-upgrade verso le release) e
#      test-verify-image.sh (il controllo dell'immagine, giusta e rotta)
#
#   --quick salta 5 e test-verify-image (niente kernel da scaricare).
#
# Serve: git, make, gcc, patch, python3, shellcheck, squashfs-tools, mtools,
# device-tree-compiler, u-boot-tools, fdisk; per 5 anche gcc-aarch64-linux-gnu.
set -euo pipefail

O="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(dirname "$O")/batocera-rf35h-check"
TREE=""
KSRC=()
QUICK=no
while [ $# -gt 0 ]; do
	case "$1" in
		--tree) TREE="$2"; shift 2 ;;
		--work) WORK="$2"; shift 2 ;;
		--kernel-src) KSRC=(--kernel-src "$2"); shift 2 ;;
		--quick) QUICK=yes; shift ;;
		-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
		*) echo "ci-check: opzione sconosciuta: $1" >&2; exit 2 ;;
	esac
done
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
TREE="${TREE:-$WORK/batocera.linux}"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
note() { [ -n "${GITHUB_ACTIONS:-}" ] && echo "::notice title=$1::$2"; return 0; }

say "1. Script"
for f in "$O"/tools/*.sh; do bash -n "$f" || die "sintassi: $f"; done
command -v shellcheck >/dev/null || die "manca shellcheck"
shellcheck -S warning "$O"/tools/*.sh || die "shellcheck"
if command -v actionlint >/dev/null; then
	actionlint "$O"/.github/workflows/*.yml || die "actionlint"
else
	echo "  actionlint non c'e': workflow non controllati"
fi

say "2. Loader"
(cd "$O/board/loader" && sha256sum -c --quiet known-good.sha256) || die "known-good.bin non corrisponde a known-good.sha256"
echo "  known-good.bin: $(cut -d' ' -f1 "$O/board/loader/known-good.sha256")"

say "3. Patch su Batocera"
"$O/tools/apply.sh" --tree "$TREE"

say "4. Configurazione del target rf35h"
OUT="$WORK/out-rf35h"
rm -rf "$OUT"; mkdir -p "$OUT"
: > "$WORK/empty_user_defconfig"
"$TREE/configs/createDefconfig.sh" "$TREE/configs/batocera-rf35h.board" "$WORK/empty_user_defconfig" "$TREE/configs/batocera-rf35h_defconfig"
make -s -C "$TREE/buildroot" O="$OUT" BR2_EXTERNAL="$TREE" batocera-rf35h_defconfig > "$WORK/defconfig.log" 2>&1 \
	|| { tail -20 "$WORK/defconfig.log"; die "make batocera-rf35h_defconfig"; }
make -s -C "$OUT" show-info > "$WORK/show-info.json" 2> "$WORK/show-info.err" \
	|| { tail -20 "$WORK/show-info.err"; die "make show-info"; }
python3 - "$OUT/.config" "$WORK/show-info.json" <<'PY'
import json, re, sys
cfg = open(sys.argv[1]).read()
info = json.load(open(sys.argv[2]))
pk = {k for k, v in info.items() if v.get('type') in ('target', 'host')}
errs = []
def val(sym):
    m = re.search(r'^%s=(.*)$' % sym, cfg, re.M)
    return m.group(1) if m else None
if val('BR2_TARGET_BATOCERA_IMAGES') != '"rockchip/rk3326/rf35h rockchip/rk3326/mainline"':
    errs.append('BR2_TARGET_BATOCERA_IMAGES = %s' % val('BR2_TARGET_BATOCERA_IMAGES'))
if 'rockchip/rk3326-xifan-rf35h' not in (val('BR2_LINUX_KERNEL_INTREE_DTS_NAME') or ''):
    errs.append('rk3326-xifan-rf35h manca da BR2_LINUX_KERNEL_INTREE_DTS_NAME')
if val('BR2_PACKAGE_BATOCERA_RF35H_SLIM') != 'y':
    errs.append('BR2_PACKAGE_BATOCERA_RF35H_SLIM non e\' attivo')
need = ['linux', 'rk915', 'rocknix-joypad', 'uboot-rk3326-mainline', 'host-uboot-tools',
        'host-genimage', 'batocera-emulationstation', 'retroarch', 'batocera-scripts']
gone = ['kodi', 'mame', 'libretro-mame', 'moonlight-qt', 'qt6base', 'uboot-rk3326']
for p in need:
    if p not in pk: errs.append('manca il pacchetto %s' % p)
for p in gone:
    if p in pk: errs.append('c\'e\' %s, che il profilo snello toglie' % p)
lr = sorted(p[len('libretro-'):] for p in pk if p.startswith('libretro-') and p != 'libretro-core-info')
print('  %d pacchetti (%d per l\'host), %d core libretro' % (len(pk), sum(1 for p in pk if p.startswith('host-')), len(lr)))
print('  linux %s, rk915 %s, rocknix-joypad %s' % tuple(info[p]['version'][:12] for p in ('linux', 'rk915', 'rocknix-joypad')))
if errs:
    for e in errs: print('  [x] ' + e)
    sys.exit(1)
open(sys.argv[2] + '.summary', 'w').write('%d pacchetti, %d core libretro' % (len(pk), len(lr)))
PY
note "Configurazione" "target rf35h: $(cat "$WORK/show-info.json.summary")"

if [ "$QUICK" = no ]; then
	say "5. Kernel: DTB e moduli"
	"$O/tools/check-dtb.sh" --tree "$TREE" --work "$WORK/kernel" "${KSRC[@]}"
fi

say "6. Test"
"$O/tools/test-upgrade.sh" "$TREE"
if [ "$QUICK" = no ]; then
	"$O/tools/test-verify-image.sh" "$TREE" "$WORK/kernel/rk3326-xifan-rf35h.dtb"
fi

say "Controlli superati"
