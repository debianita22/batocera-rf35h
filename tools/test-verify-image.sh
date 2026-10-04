#!/bin/bash
# test-verify-image.sh - verify-image.sh su un'immagine finta, giusta e rotta.
#
#   tools/test-verify-image.sh BATOCERA_TREE DTB
#
# BATOCERA_TREE: l'albero dopo tools/apply.sh (ne prende extlinux.conf,
# boot.cmd, es_input.cfg e batocera-upgrade veri); DTB: rk3326-xifan-rf35h.dtb
# compilato (tools/check-dtb.sh lo lascia nella sua cartella di lavoro).
#
# Costruisce un'immagine con la stessa struttura di quella di Batocera (loader
# a 32K, FAT da 16 MiB, squashfs dentro la FAT, boot.tar.xz accanto) ma con
# file piccoli, controlla che verify-image.sh dica "Conforme", poi rompe una
# cosa alla volta e controlla che ogni volta dica "NON conforme": un controllo
# che passa anche col difetto non serve a niente.
set -euo pipefail

TREE="${1:?uso: test-verify-image.sh BATOCERA_TREE DTB}"
DTB_IN="${2:?uso: test-verify-image.sh BATOCERA_TREE DTB}"
O="$(cd "$(dirname "$0")/.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/rf35h-tvi.XXXXXX")"
trap 'rm -rf "$W"' EXIT
export MTOOLS_SKIP_CHECK=1

RF="$TREE/board/batocera/rockchip/rk3326/rf35h"
VER="44-dev-3b66740.rf35h-test 2026/10/04 18:00"

# $1: cartella di lavoro; $2: la mutazione da fare (vuota: nessuna)
make_image() {
	local d="$1" mut="${2:-}"
	rm -rf "$d"; mkdir -p "$d/root" "$d/boot/boot" "$d/boot/extlinux" "$d/out"

	# il sistema
	local r="$d/root"
	mkdir -p "$r/lib/modules/7.2.8/extra" "$r/lib/firmware" "$r/usr/share/emulationstation" \
	         "$r/usr/bin" "$r/usr/share/batocera" "$r/usr/lib/libretro"
	printf 'xx\0rumble setup success (gpio)\n\0yy' > "$r/lib/modules/7.2.8/extra/rocknix-singleadc-joypad.ko"
	echo rk915 > "$r/lib/modules/7.2.8/extra/rk915.ko"
	echo fw > "$r/lib/firmware/rk915_fw.bin"; echo patch > "$r/lib/firmware/rk915_patch.bin"
	cp "$TREE/package/batocera/emulationstation/batocera-emulationstation/controllers/es_input.cfg" "$r/usr/share/emulationstation/"
	cp "$TREE/package/batocera/core/batocera-scripts/scripts/batocera-upgrade" "$r/usr/bin/"
	echo "$VER" > "$r/usr/share/batocera/batocera.version"
	echo core > "$r/usr/lib/libretro/mame078plus_libretro.so"
	case "$mut" in
		joypad-unpatched) echo plain > "$r/lib/modules/7.2.8/extra/rocknix-singleadc-joypad.ko" ;;
		no-rk915-fw)      rm "$r/lib/firmware/rk915_patch.bin" ;;
		es-hotkey-mode)   sed -i '/deviceName="XiFan RF35H Gamepad"/,/<\/inputConfig>/ s|<input name="hotkey" type="button" id="8" value="1" code="314" />|<input name="hotkey" type="button" id="10" value="1" code="316" />|' "$r/usr/share/emulationstation/es_input.cfg" ;;
		upgrade-official) sed -i 's|^G_UPDATEURL=.*|G_UPDATEURL="https://updates.batocera.org"|' "$r/usr/bin/batocera-upgrade" ;;
		version-plain)    echo "44-dev-3b66740 2026/10/04 18:00" > "$r/usr/share/batocera/batocera.version" ;;
		not-slim)         mkdir -p "$r/usr/bin/mame" && echo x > "$r/usr/bin/mame/mame" ;;
		not-slim-core)    echo core > "$r/usr/lib/libretro/mame_libretro.so" ;;
	esac
	mksquashfs "$r" "$d/system.squashfs" -quiet -noappend -comp gzip >/dev/null

	# la partizione di avvio
	local b="$d/boot"
	echo kernel > "$b/linux"; echo initrd > "$b/initrd.lz4"
	cp "$DTB_IN" "$b/rk3326-xifan-rf35h.dtb"
	cp "$RF/extlinux/extlinux.conf" "$b/extlinux/"
	cp "$RF/boot/boot.cmd" "$d/boot.cmd"
	case "$mut" in
		console-ttys2) sed -i 's/console=ttyS1,/console=ttyS2,/' "$b/extlinux/extlinux.conf" ;;
		fdt-other)     sed -i 's|FDT /rk3326-xifan-rf35h.dtb|FDT /rk3326-odroid-go2.dtb|' "$b/extlinux/extlinux.conf" ;;
		scr-low-kernel) sed -i 's/0x09000000/0x02080000/' "$d/boot.cmd" ;;
		dtb-old-joypad) fdtput -t s "$b/rk3326-xifan-rf35h.dtb" /rocknix-singleadc-joypad joypad-name retrogame_joypad ;;
		dtb-no-rumble)  fdtput -d "$b/rk3326-xifan-rf35h.dtb" /rocknix-singleadc-joypad rumble-gpios ;;
		dtb-58hz)       fdtput -t s "$b/rk3326-xifan-rf35h.dtb" /dsi@ff450000/panel@0 panel_description "G size=52,70" "M clock=31080 horizontal=640,150,60,150 vertical=480,20,6,12" ;;
	esac
	mkimage -C none -A arm64 -T script -n batocera-rf35h -d "$d/boot.cmd" "$b/boot.scr" >/dev/null
	cp "$d/system.squashfs" "$b/boot/batocera.update"
	echo rufo > "$b/boot/rufomaculata.update"
	echo "rf35h" > "$b/boot/batocera.board"
	[ "$mut" = board-other ] && echo "rk3326" > "$b/boot/batocera.board"
	echo "# conf" > "$b/batocera-boot.conf"
	# come post-image-script.sh: tar con i nomi relativi, senza ./
	(cd "$b" && tar -cJf "$d/out/boot.tar.xz" -- *)
	md5sum "$d/out/boot.tar.xz" | cut -d' ' -f1 > "$d/out/boot.tar.xz.md5"
	[ "$mut" = md5-wrong ] && echo 0123 > "$d/out/boot.tar.xz.md5"
	echo "$VER" > "$d/out/batocera.version"
	[ "$mut" = spi-loader ] && { echo spi > "$b/boot/u-boot-rockchip-spi.bin"; (cd "$b" && tar -cJf "$d/out/boot.tar.xz" -- *); md5sum "$d/out/boot.tar.xz" | cut -d' ' -f1 > "$d/out/boot.tar.xz.md5"; rm "$b/boot/u-boot-rockchip-spi.bin"; }
	# nell'immagine il sistema si chiama boot/batocera (post-image-script.sh)
	mv "$b/boot/batocera.update" "$b/boot/batocera"
	mv "$b/boot/rufomaculata.update" "$b/boot/rufomaculata"

	# la FAT (64 MiB bastano) e la scheda
	local fat="$d/boot.vfat"
	dd if=/dev/zero of="$fat" bs=1M count=0 seek=64 status=none
	mformat -i "$fat" -F -v BATOCERA ::
	mcopy -s -i "$fat" "$b"/* ::
	local img="$d/out/batocera-rk3326-rf35h-44-20261004.img"
	dd if=/dev/zero of="$img" bs=1M count=0 seek=96 status=none
	local start=32768 fats=$((64 * 2048))
	local p1="${img}1 : start=${start}, size=${fats}, type=c, bootable"
	local p2="${img}2 : start=$((start + fats)), size=8192, type=83"
	[ "$mut" = fat-at-8m ] && p1="${img}1 : start=16384, size=${fats}, type=c, bootable" && p2="${img}2 : start=$((16384 + fats)), size=8192, type=83"
	[ "$mut" = not-bootable ] && p1="${img}1 : start=${start}, size=${fats}, type=c"
	printf 'label: dos\nunit: sectors\n\n%s\n%s\n' "$p1" "$p2" | sfdisk -q "$img"
	dd if="$O/board/loader/known-good.bin" of="$img" bs=32K seek=1 conv=notrunc status=none
	[ "$mut" = loader-flip ] && printf '\x00' | dd of="$img" bs=1 seek=$((32768 + 4096)) conv=notrunc status=none
	if [ "$mut" = fat-at-8m ]; then
		dd if="$fat" of="$img" bs=1M seek=8 conv=notrunc status=none
	else
		dd if="$fat" of="$img" bs=1M seek=16 conv=notrunc status=none
	fi
	gzip -1 "$img"
}

run_verify() { "$O/tools/verify-image.sh" "$1/out" > "$1/verify.log" 2>&1; }

pass=0; fail=0
echo "==> immagine giusta"
make_image "$W/good"
if run_verify "$W/good" && tail -1 "$W/good/verify.log" | grep -qx Conforme; then
	echo "  ok  Conforme"; pass=$((pass + 1))
else
	echo "  NO  l'immagine giusta non risulta conforme:"; sed 's/^/      /' "$W/good/verify.log"; fail=$((fail + 1))
fi

echo "==> mutazioni (ognuna deve dare NON conforme)"
for m in loader-flip fat-at-8m not-bootable console-ttys2 fdt-other scr-low-kernel board-other \
         dtb-old-joypad dtb-no-rumble dtb-58hz joypad-unpatched no-rk915-fw es-hotkey-mode \
         upgrade-official version-plain not-slim not-slim-core md5-wrong spi-loader; do
	make_image "$W/$m" "$m"
	if run_verify "$W/$m"; then
		echo "  NO  $m: risulta conforme"; fail=$((fail + 1))
	elif grep -q '^NON conforme' "$W/$m/verify.log"; then
		echo "  ok  $m ($(grep -c '^  NO ' "$W/$m/verify.log") controllo/i)"; pass=$((pass + 1))
	else
		echo "  NO  $m: verify-image.sh non ha finito:"; tail -5 "$W/$m/verify.log" | sed 's/^/      /'; fail=$((fail + 1))
	fi
	rm -rf "${W:?}/$m"
done
echo
echo "test-verify-image: $pass ok, $fail falliti"
[ "$fail" -eq 0 ]
