#!/bin/bash
# check-dtb.sh - DTB e moduli dell'RF35H compilati contro il kernel di Batocera.
#
#   tools/check-dtb.sh [--tree DIR] [--work DIR] [--kernel-src DIR]
#
# In pochi minuti, senza la build intera: prende il kernel che il board file
# RK3326 di Batocera indica (BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE), ci mette
# le patch e i device tree della board come fa buildroot (patch in ordine di
# nome, cartella dts copiata sopra quella del kernel), lo configura con la loro
# config, e poi:
#
#   - compila rk3326-xifan-rf35h.dtb con W=1: nessun avviso da quel file
#   - compila rocknix-joypad e rk915 alla versione e con le patch dei loro
#     pacchetti (moduli esterni, cross gcc aarch64): nessun errore, e il joypad
#     contiene la patch del motore su GPIO
#
# Serve quando si sposta batocera.pin: se Batocera cambia kernel, patch o
# driver, ce ne si accorge qui e non dopo ore di build. Il DTB resta in
# WORK/rk3326-xifan-rf35h.dtb (lo usa tools/test-verify-image.sh).
#
# Il kernel: --kernel-src (un albero pulito della stessa versione, che viene
# copiato), altrimenti il tarball di cdn.kernel.org, altrimenti il tag del
# mirror gregkh/linux su GitHub. Serve aarch64-linux-gnu-gcc.
set -euo pipefail

O="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$(dirname "$O")/batocera.linux"
WORK=""
KSRC=""
while [ $# -gt 0 ]; do
	case "$1" in
		--tree) TREE="$2"; shift 2 ;;
		--work) WORK="$2"; shift 2 ;;
		--kernel-src) KSRC="$2"; shift 2 ;;
		-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
		*) echo "check-dtb: opzione sconosciuta: $1" >&2; exit 2 ;;
	esac
done
WORK="${WORK:-$(dirname "$O")/batocera-rf35h-check}"
say() { printf '==> %s\n' "$*"; }
die() { printf 'check-dtb: %s\n' "$*" >&2; exit 1; }
command -v aarch64-linux-gnu-gcc >/dev/null || die "manca aarch64-linux-gnu-gcc (Debian/Ubuntu: gcc-aarch64-linux-gnu)"

B="$TREE/board/batocera/rockchip/rk3326"
BOARD="$TREE/configs/batocera-rk3326.board"
[ -f "$BOARD" ] || die "$TREE non e' un albero di Batocera"
[ -f "$B/dts/rockchip/rk3326-xifan-rf35h.dts" ] || die "$TREE non ha il DTS dell'RF35H: prima tools/apply.sh"
KVER="$(sed -n 's/^BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE="\(.*\)"$/\1/p' "$BOARD")"
[ -n "$KVER" ] || die "versione del kernel non trovata in $BOARD"
grep -q 'rockchip/rk3326-xifan-rf35h' "$BOARD" || die "rk3326-xifan-rf35h non e' in BR2_LINUX_KERNEL_INTREE_DTS_NAME"

mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
K="$WORK/linux-$KVER"
MAKEK=(make -s -C "$K" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-)

say "Kernel $KVER"
rm -rf "$K"
if [ -n "$KSRC" ]; then
	[ "$(make -s -C "$KSRC" kernelversion 2>/dev/null)" = "$KVER" ] || die "--kernel-src non e' la $KVER"
	mkdir -p "$K"
	(cd "$KSRC" && git archive --format=tar HEAD 2>/dev/null || tar --exclude=.git -cf - .) | tar -xf - -C "$K"
else
	MAJOR="${KVER%%.*}"
	if curl -fsSL "https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/linux-${KVER}.tar.xz" -o "$WORK/linux.tar.xz"; then
		mkdir -p "$K" && tar -xJf "$WORK/linux.tar.xz" -C "$K" --strip-components=1 && rm -f "$WORK/linux.tar.xz"
	else
		git clone -q --depth 1 --branch "v$KVER" https://github.com/gregkh/linux.git "$K" || die "kernel $KVER non scaricabile"
		rm -rf "$K/.git"
	fi
fi

say "Patch della board ($(find "$B/linux_patches" -name '*.patch' | wc -l))"
while IFS= read -r p; do
	patch -g0 -p1 -E -s -N -d "$K" < "$B/linux_patches/$p" || die "patch $p non si applica alla $KVER"
done < <(cd "$B/linux_patches" && LC_ALL=C ls -1 -- *.patch)
cp -r -f "$B/dts/rockchip" "$K/arch/arm64/boot/dts/"
cp "$B/linux-defconfig.config" "$K/.config"
(cd "$K" && ARCH=arm64 scripts/kconfig/merge_config.sh -m .config "$B/linux-defconfig-fragment.config" >/dev/null)
"${MAKEK[@]}" olddefconfig

say "DTB (W=1)"
LOG="$WORK/dtb.log"
"${MAKEK[@]}" W=1 rockchip/rk3326-xifan-rf35h.dtb > "$LOG" 2>&1 || { cat "$LOG"; die "il DTB non compila"; }
if grep -q 'rk3326-xifan-rf35h\.dts' "$LOG"; then
	grep 'rk3326-xifan-rf35h\.dts' "$LOG"
	die "avvisi da rk3326-xifan-rf35h.dts"
fi
cp "$K/arch/arm64/boot/dts/rockchip/rk3326-xifan-rf35h.dtb" "$WORK/"
echo "    $WORK/rk3326-xifan-rf35h.dtb ($(stat -c%s "$WORK/rk3326-xifan-rf35h.dtb") byte)"

say "Moduli esterni"
"${MAKEK[@]}" modules_prepare

# $1 nome del pacchetto, $2 prefisso delle variabili nel .mk, $3 make extra
module() {
	local pkg="$1" var="$2" extra="$3" mk ver site dir
	mk="$TREE/package/batocera/$(cd "$TREE/package/batocera" && find . -name "$pkg.mk" -printf '%P\n' | head -1)"
	[ -f "$mk" ] || die "$pkg.mk non trovato"
	ver="$(sed -n "s/^${var}_VERSION *= *\([0-9a-f]\{40\}\).*/\1/p" "$mk")"
	site="$(sed -n "s/^${var}_SITE *= *\$(call github,\([^,]*\),\([^,]*\),.*/\1\/\2/p" "$mk")"
	[ -n "$ver" ] && [ -n "$site" ] || die "$pkg: versione o sito non letti da $mk"
	dir="$WORK/$pkg"
	rm -rf "$dir"
	git clone -q --filter=blob:none "https://github.com/$site.git" "$dir" || die "$pkg: $site non scaricabile"
	git -C "$dir" checkout -q "$ver" || die "$pkg: commit $ver non trovato"
	rm -rf "$dir/.git"
	local p
	for p in "$(dirname "$mk")"/*.patch; do
		[ -f "$p" ] || continue
		patch -g0 -p1 -E -s -d "$dir" < "$p" || die "$pkg: $(basename "$p") non si applica"
	done
	# shellcheck disable=SC2086
	"${MAKEK[@]}" M="$dir" KBUILD_MODPOST_WARN=1 $extra modules > "$WORK/$pkg.log" 2>&1 \
		|| { tail -30 "$WORK/$pkg.log"; die "$pkg non compila"; }
	if grep -E '(error|warning):' "$WORK/$pkg.log" | grep -v 'modpost\|Module.symvers' | grep -q .; then
		echo "    $pkg: avvisi del compilatore (del codice di $site):"
		grep -E '(error|warning):' "$WORK/$pkg.log" | grep -v 'modpost\|Module.symvers' | sed 's/^/      /' | head -10
	fi
	echo "    $pkg ${ver:0:7}: $(cd "$dir" && ls -- *.ko | tr '\n' ' ')"
}
module rocknix-joypad ROCKNIX_JOYPAD "DEVICE=RK3326"
grep -qa 'rumble setup success (gpio)' "$WORK/rocknix-joypad/rocknix-singleadc-joypad.ko" \
	|| die "rocknix-singleadc-joypad.ko senza la patch del motore su GPIO"
module rk915 RK915 "CONFIG_RK915=m USER_EXTRA_CFLAGS=-Wno-error"

say "Tutto compila"
