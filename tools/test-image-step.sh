#!/bin/bash
# test-image-step.sh - l'ultimo passo della build, quello che fa le immagini:
# gli script veri di Batocera e i nostri, su file finti.
#
#   tools/test-image-step.sh BATOCERA_TREE DTB CONFIG [GENIMAGE_DIR]
#
# BATOCERA_TREE: l'albero dopo tools/apply.sh; DTB: rk3326-xifan-rf35h.dtb
# compilato (tools/check-dtb.sh); CONFIG: il .config del target rf35h
# (tools/ci-check.sh, passo 4), da cui post-image-script.sh legge il target e
# le immagini da fare; GENIMAGE_DIR: dove compilare genimage (predefinita: una
# cartella temporanea), riusato se c'e' gia'.
#
# In una build vera post-image-script.sh gira una volta sola, alla fine
# dell'ultima parte: un errore nei create-boot-script.sh o nei genimage.cfg si
# vedrebbe dopo un giorno e piu' di build. Qui gira in un minuto, su una
# cartella delle immagini finta: kernel, initrd, U-Boot mainline e DTB delle
# altre console finti, i due squashfs di test-verify-image.sh, il nostro DTB e
# il loader known-good veri. genimage e' quello del buildroot fissato (stessa
# versione, sorgente controllato col .hash di buildroot); mkimage, mtools,
# dosfstools ed e2fsprogs sono quelli del sistema. Poi:
#
#   post-image-script.sh   esce 0 e fa le due immagini, coi nomi che si
#                          aspetta ci-build.sh
#   immagine mainline      U-Boot a 32K, 8M e 12M; nella FAT il DTB della
#                          RF35H e extlinux.conf.rf35h (FDT della RF35H,
#                          console ttyS1)
#   collect e verdict      ci-build.sh sulla cartella fatta da
#                          post-image-script.sh: verify-image.sh dice
#                          "Conforme", i file della release in dist,
#                          l'immagine mainline in upstream, verdict passa
#
# Serve: gcc, make, pkg-config e libconfuse-dev (per genimage), curl,
# u-boot-tools, mtools, dosfstools, e2fsprogs, squashfs-tools, fdisk, xz,
# zstd.
set -euo pipefail

TREE="${1:?uso: test-image-step.sh BATOCERA_TREE DTB CONFIG [GENIMAGE_DIR]}"
DTB="${2:?uso: test-image-step.sh BATOCERA_TREE DTB CONFIG [GENIMAGE_DIR]}"
CONFIG="${3:?uso: test-image-step.sh BATOCERA_TREE DTB CONFIG [GENIMAGE_DIR]}"
GI_DIR="${4:-}"
O="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/rf35h-tis.XXXXXX")"
trap 'rm -rf "$T"' EXIT
export MTOOLS_SKIP_CHECK=1

die() { echo "test-image-step: $*" >&2; exit 2; }
pass=0; fail=0
ok()  { echo "  ok  $*"; pass=$((pass + 1)); }
bad() { echo "  NO  $*"; fail=$((fail + 1)); }

POST="$TREE/board/batocera/scripts/post-image-script.sh"
ML="$TREE/board/batocera/rockchip/rk3326/mainline"
for f in "$POST" "$ML/create-boot-script.sh" "$DTB" "$CONFIG"; do
	[ -f "$f" ] || die "$f non esiste"
done
[ -f "$TREE/.rf35h-overlay" ] || die "$TREE non e' preparato da tools/apply.sh"

# --- genimage, la versione del buildroot fissato -----------------------------
echo "==> genimage"
GMK="$TREE/buildroot/package/genimage/genimage.mk"
GVER="$(sed -n 's/^GENIMAGE_VERSION = *//p' "$GMK")"
[ -n "$GVER" ] || die "GENIMAGE_VERSION non trovata in $GMK"
GI_DIR="${GI_DIR:-$T/genimage}"
mkdir -p "$GI_DIR"; GI_DIR="$(cd "$GI_DIR" && pwd)"
GENIMAGE="$GI_DIR/bin/genimage"
if [ -x "$GENIMAGE" ] && [ "$("$GENIMAGE" --version 2>/dev/null)" = "$GVER" ]; then
	echo "  genimage $GVER gia' compilato in $GI_DIR"
else
	src="$(sed -n 's/^GENIMAGE_SOURCE = *//p' "$GMK")"; src="${src//\$(GENIMAGE_VERSION)/$GVER}"
	site="$(sed -n 's/^GENIMAGE_SITE = *//p' "$GMK")"; site="${site//\$(GENIMAGE_VERSION)/$GVER}"
	sum="$(awk -v f="$src" '$1 == "sha256" && $3 == f {print $2}' "${GMK%.mk}.hash")"
	[ -n "$src" ] && [ -n "$site" ] && [ -n "$sum" ] || die "sorgente, sito o hash di genimage non trovati"
	curl -sSfL --retry 3 -o "$T/$src" "$site/$src" || die "scaricamento di $site/$src"
	echo "$sum  $T/$src" | sha256sum -c --quiet - || die "$src non corrisponde a genimage.hash di buildroot"
	tar -C "$T" -xf "$T/$src"
	if ! (cd "$T/genimage-$GVER" && ./configure --prefix="$GI_DIR" && make -j"$(nproc)" && make install) > "$T/genimage-build.log" 2>&1; then
		tail -15 "$T/genimage-build.log" >&2
		die "genimage $GVER non si compila (serve libconfuse-dev e pkg-config)"
	fi
	[ "$("$GENIMAGE" --version)" = "$GVER" ] || die "genimage compilato non e' la versione $GVER"
	echo "  genimage $GVER compilato da $site/$src (sha256 di buildroot)"
fi

# --- la cartella di buildroot finta, dove ci-build.sh la cerca ----------------
W="$T/w"
OUT="$W/work/output/rf35h"
BIN="$OUT/images" HOST="$OUT/host" BUILD="$OUT/build" TGT="$OUT/target"
mkdir -p "$BIN/uboot-rk3326-mainline" "$BIN/tools" "$HOST/bin" "$BUILD" \
         "$TGT/usr/share/batocera" "$TGT/userdata/system"

# i due squashfs giusti (contenuto controllato da verify-image.sh) e la versione
"$O/tools/test-verify-image.sh" --make-system "$TREE" "$DTB" "$BIN"
mv "$BIN/batocera.version" "$TGT/usr/share/batocera/batocera.version"
VER="$(cat "$TGT/usr/share/batocera/batocera.version")"
echo "data" > "$TGT/userdata/system/batocera.conf"

echo kernel > "$BIN/Image"
echo initrd > "$BIN/initrd.lz4"
# i DTB che copia create-boot-script.sh di mainline: il nostro vero, gli altri finti
DTBS="$(sed -n '/^DTBS="/,/"/p' "$ML/create-boot-script.sh" | tr -d '"' | sed 's/^DTBS=//')"
for d in $DTBS; do echo "fake $d" > "$BIN/$d.dtb"; done
cp "$DTB" "$BIN/rk3326-xifan-rf35h.dtb"
# U-Boot mainline: contenuti diversi, per vedere dove finiscono
for u in idbloader uboot trust; do
	{ printf 'UBOOT-%s-' "$u"; head -c 4000 /dev/zero | tr '\0' "${u:0:1}"; } > "$BIN/uboot-rk3326-mainline/$u.img"
done
echo "tools" > "$BIN/tools/readme.txt"
echo "# batocera-boot.conf" > "$BIN/batocera-boot.conf"
ln -s "$(command -v mkimage)" "$HOST/bin/mkimage"
ln -s "$GENIMAGE" "$HOST/bin/genimage"

# --- post-image-script.sh, come lo chiama buildroot -----------------------------
# (Makefile, target-post-image: $(EXTRA_ENV) script $(BINARIES_DIR), con le
# variabili esportate; lo script ha "#!/bin/bash -e", quindi si esegue lui)
echo "==> post-image-script.sh (rf35h e mainline)"
rc=0
(
	cd "$TREE/buildroot"
	env PATH="$HOST/bin:$HOST/sbin:$PATH" BUILD_DIR="$BUILD" BASE_DIR="$OUT" \
	    BR2_CONFIG="$CONFIG" BR2_EXTERNAL_BATOCERA_PATH="$TREE" \
	    HOST_DIR="$HOST" TARGET_DIR="$TGT" BINARIES_DIR="$BIN" STAGING_DIR="$HOST/staging" \
	    "$POST" "$BIN"
) > "$T/post-image.log" 2>&1 || rc=$?
if [ "$rc" = 0 ]; then
	ok "post-image-script.sh esce 0"
else
	bad "post-image-script.sh esce $rc:"; tail -20 "$T/post-image.log" | sed 's/^/      /'
	echo; echo "test-image-step: $pass ok, $fail falliti"; exit 1
fi

IMG="$BIN/batocera/images"
SV="${VER%%[!0-9.]*}"	# come SUFFIXVERSION in post-image-script.sh
rf=("$IMG"/rf35h/batocera-rk3326-rf35h-"$SV"-*.img.gz)
ml=("$IMG"/mainline/batocera-rk3326-mainline-"$SV"-*.img.gz)
if [ "${#rf[@]}" = 1 ] && [ -f "${rf[0]}" ] && [ "${#ml[@]}" = 1 ] && [ -f "${ml[0]}" ]; then
	ok "immagini: $(basename "${rf[0]}"), $(basename "${ml[0]}")"
else
	bad "immagini: $(cd "$IMG" && find . -type f | sort | tr '\n' ' ')"
fi

# --- l'immagine mainline ------------------------------------------------------
echo "==> immagine mainline"
if [ -f "${ml[0]}" ]; then
	mimg="$T/mainline.img"
	gzip -dc "${ml[0]}" | dd of="$mimg" bs=1M conv=sparse status=none
	at() {	# offset in KiB, file
		local n; n="$(stat -c%s "$2")"
		cmp -s -n "$n" "$2" <(dd if="$mimg" bs=1K skip="$1" count=$(( (n + 1023) / 1024 )) status=none)
	}
	u="$BIN/uboot-rk3326-mainline"
	if at 32 "$u/idbloader.img" && at 8192 "$u/uboot.img" && at 12288 "$u/trust.img"; then
		ok "U-Boot mainline a 32K, 8M e 12M"
	else
		bad "U-Boot mainline non e' a 32K, 8M e 12M"
	fi
	p1="$(sfdisk -d "$mimg" 2>/dev/null | sed -n 's/.*1 : start= *\([0-9]*\),.*/\1/p')"
	fat="$mimg@@$(( ${p1:-0} * 512 ))"
	if mtype -i "$fat" ::/extlinux/extlinux.conf.rf35h > "$T/ext.rf35h" 2>/dev/null; then
		if grep -q 'FDT /rk3326-xifan-rf35h.dtb' "$T/ext.rf35h" && grep -q 'console=ttyS1,' "$T/ext.rf35h" \
		   && ! grep -q 'console=ttyS2' "$T/ext.rf35h"; then
			ok "extlinux.conf.rf35h: FDT della RF35H, console ttyS1"
		else
			bad "extlinux.conf.rf35h:"; sed 's/^/      /' "$T/ext.rf35h"
		fi
	else
		bad "extlinux.conf.rf35h non c'e' nella FAT (partizione 1 a ${p1:-?})"
	fi
	if mcopy -n -i "$fat" ::/rk3326-xifan-rf35h.dtb "$T/ml.dtb" 2>/dev/null && cmp -s "$T/ml.dtb" "$DTB"; then
		ok "rk3326-xifan-rf35h.dtb nella FAT"
	else
		bad "rk3326-xifan-rf35h.dtb assente o diverso nella FAT"
	fi
	rm -f "$mimg"
fi

# --- collect e verdict di ci-build.sh -------------------------------------------
echo "==> collect e verdict"
ci() { env -u GITHUB_ACTIONS W="$W" RF35H_STAGE=1 "$O/tools/ci-build.sh" "$@"; }
crc=0; ci collect > "$T/collect.log" 2>&1 || crc=$?
if tail -1 "$W/verify.log" 2>/dev/null | grep -qx Conforme; then
	ok "verify-image.sh sull'immagine rf35h: Conforme"
else
	bad "verify-image.sh sull'immagine rf35h:"
	{ grep -E '^  NO ' "$W/verify.log"; tail -1 "$W/verify.log"; } 2>/dev/null | sed 's/^/      /'
fi
dist="$(cd "$W/dist" 2>/dev/null && ls | tr '\n' ' ')"
if [ "$crc" = 0 ] && ls "$W"/dist/batocera-rk3326-rf35h-*.img.gz >/dev/null 2>&1 \
   && [ -f "$W/dist/boot.tar.xz" ] && [ -f "$W/dist/boot.tar.xz.md5" ] && [ -f "$W/dist/SHA256SUMS" ] \
   && [ "$(cat "$W/dist/batocera.version" 2>/dev/null)" = "$VER" ]; then
	ok "collect: dist con $dist"
else
	bad "collect esce $crc, dist: $dist"; tail -5 "$T/collect.log" | sed 's/^/      /'
fi
if ls "$W"/upstream/batocera-rk3326-mainline-*.img.gz >/dev/null 2>&1 && [ -f "$W/upstream/batocera.version" ]; then
	ok "collect: immagine mainline in upstream"
else
	bad "collect: upstream: $(ls "$W/upstream" 2>/dev/null | tr '\n' ' ')"
fi
vrc=0; ci verdict > "$T/verdict.log" 2>&1 || vrc=$?
if [ "$vrc" = 0 ]; then ok "verdict passa"; else bad "verdict fallisce:"; sed 's/^/      /' "$T/verdict.log"; fi

echo
echo "test-image-step: $pass ok, $fail falliti"
[ "$fail" -eq 0 ]
