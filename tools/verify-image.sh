#!/bin/bash
# verify-image.sh - controlla un'immagine rf35h appena costruita.
#
#   tools/verify-image.sh DIR
#
# DIR e' la cartella dell'immagine rf35h (WORK/output/rf35h/images/batocera/
# images/rf35h): batocera-rk3326-rf35h-*.img.gz, boot.tar.xz (+ .md5),
# batocera.version. Si guarda dentro senza montare niente (sfdisk, mtools,
# unsquashfs, fdtget) e si confronta con quello che questo repo dichiara:
#
#   scheda    il loader known-good a 32K, byte per byte; la FAT da 16 MiB,
#             tipo 0x0c e avviabile; la partizione SHARE dopo
#   avvio     boot.scr (script: sysboot su extlinux.conf, kernel_addr_r
#             0x09000000), extlinux.conf (FDT dell'RF35H, console ttyS1),
#             kernel, initrd, DTB, batocera.board = rf35h
#   DTB       modello, joypad con l'identita' e il motore su GPIO, nodo RK915,
#             modo a 60 Hz predefinito
#   sistema   i due squashfs (boot/batocera e boot/rufomaculata: Batocera
#             mette nel secondo usr/lib/libretro e usr/bin/mame, e l'initrd li
#             monta insieme): i moduli rk915 e rocknix-singleadc-joypad, con
#             la patch del motore; i firmware RK915; l'alias che carica rk915;
#             il pad in es_input.cfg; batocera-upgrade verso le release, ed
#             EmulationStation che non lo riscarica da GitHub; i core
#             libretro principali; niente Kodi, MAME attuale, Moonlight
#             (profilo snello)
#   update    boot.tar.xz con lo stesso sistema, la sua .md5, batocera.version
#
# Esce 0 con "Conforme", 1 con "NON conforme" e l'elenco di cosa manca.
set -uo pipefail

DIR="${1:?uso: verify-image.sh DIR}"
O="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/rf35h-verify.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
ok()  { printf '  ok  %s\n' "$*"; }
bad() { printf '  NO  %s\n' "$*"; FAIL=$((FAIL + 1)); }
chk() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

for t in sfdisk mtype mcopy unsquashfs fdtget dumpimage xz md5sum; do
	command -v "$t" >/dev/null || { echo "verify: manca $t (mtools, squashfs-tools, device-tree-compiler, u-boot-tools, fdisk, xz-utils)" >&2; exit 2; }
done

shopt -s nullglob
imgs=("$DIR"/batocera-rk3326-rf35h-*.img.gz "$DIR"/batocera-rk3326-rf35h-*.img)
[ "${#imgs[@]}" -eq 1 ] || { echo "verify: in $DIR serve una sola immagine batocera-rk3326-rf35h-*.img[.gz], trovate ${#imgs[@]}" >&2; exit 2; }
IMG_SRC="${imgs[0]}"
echo "==> $(basename "$IMG_SRC")"

IMG="$TMP/disk.img"
case "$IMG_SRC" in
	*.gz) gzip -dc "$IMG_SRC" | dd of="$IMG" bs=1M conv=sparse status=none ;;
	*)    cp --sparse=always "$IMG_SRC" "$IMG" ;;
esac

echo "-- scheda"
LOADER="$O/board/loader/known-good.bin"
chk "loader known-good a 32K (byte per byte)" \
	cmp -n "$(stat -c%s "$LOADER")" "$LOADER" <(dd if="$IMG" bs=32K skip=1 status=none)
PT="$(sfdisk -d "$IMG" 2>/dev/null)"
p1="$(printf '%s\n' "$PT" | grep -E '^[^ ]+1 :')"
p2="$(printf '%s\n' "$PT" | grep -E '^[^ ]+2 :')"
chk "partizione 1 da 16 MiB (settore 32768)" grep -q 'start= *32768,' <<<"$p1"
chk "partizione 1 di tipo 0x0c, avviabile" bash -c 'grep -q "type=c" <<<"$1" && grep -q bootable <<<"$1"' _ "$p1"
chk "partizione 2 (SHARE) di tipo 0x83" grep -q 'type=83' <<<"$p2"

echo "-- avvio"
FAT="$IMG@@16M"
export MTOOLS_SKIP_CHECK=1
for f in linux initrd.lz4 rk3326-xifan-rf35h.dtb boot.scr extlinux/extlinux.conf \
         boot/batocera boot/rufomaculata boot/batocera.board batocera-boot.conf; do
	chk "/$f" mtype -i "$FAT" "::$f" -t
done
EXT="$(mtype -i "$FAT" ::extlinux/extlinux.conf 2>/dev/null)"
chk "extlinux.conf: FDT /rk3326-xifan-rf35h.dtb" grep -qE '^ *FDT /rk3326-xifan-rf35h\.dtb$' <<<"$EXT"
chk "extlinux.conf: console=ttyS1, nessun ttyS2" bash -c 'grep -q "console=ttyS1,1500000" <<<"$1" && ! grep -q ttyS2 <<<"$1"' _ "$EXT"
chk "extlinux.conf: kernel /linux, initrd /initrd.lz4, label=BATOCERA" \
	bash -c 'grep -qE "^ *LINUX /linux$" <<<"$1" && grep -qE "^ *INITRD /initrd.lz4$" <<<"$1" && grep -q "label=BATOCERA" <<<"$1"' _ "$EXT"
mcopy -n -i "$FAT" ::boot.scr "$TMP/boot.scr" 2>/dev/null
chk "boot.scr e' un'immagine script di U-Boot" bash -c 'dumpimage -l "$1" | grep -q "Script"' _ "$TMP/boot.scr"
SCR="$(tail -c +73 "$TMP/boot.scr" 2>/dev/null | tr -d '\0')"
chk "boot.scr: sysboot su /extlinux/extlinux.conf, kernel_addr_r 0x09000000" \
	bash -c 'grep -q "^sysboot .* /extlinux/extlinux.conf$" <<<"$1" && grep -q "kernel_addr_r \"0x09000000\"" <<<"$1"' _ "$SCR"
chk "batocera.board = rf35h" bash -c '[ "$(mtype -i "$1" ::boot/batocera.board | tr -d "\r\n ")" = rf35h ]' _ "$FAT"

echo "-- device tree"
mcopy -n -i "$FAT" ::rk3326-xifan-rf35h.dtb "$TMP/rf35h.dtb" 2>/dev/null
DTB="$TMP/rf35h.dtb"
chk "model \"XiFan RF35H\"" bash -c '[ "$(fdtget "$1" / model)" = "XiFan RF35H" ]' _ "$DTB"
chk "joypad: \"XiFan RF35H Gamepad\", 0x484b:0x1135" \
	bash -c '[ "$(fdtget "$1" /rocknix-singleadc-joypad joypad-name)" = "XiFan RF35H Gamepad" ] && [ "$(fdtget -tx "$1" /rocknix-singleadc-joypad joypad-product)" = 1135 ] && [ "$(fdtget -tx "$1" /rocknix-singleadc-joypad joypad-vendor)" = 484b ]' _ "$DTB"
chk "joypad: rumble-gpios" fdtget "$DTB" /rocknix-singleadc-joypad rumble-gpios
chk "nodo rk915-wifi (rockchip,rk915)" bash -c '[ "$(fdtget "$1" /rk915-wifi compatible)" = "rockchip,rk915" ]' _ "$DTB"
chk "pannello: 31,08 MHz predefinito (60 Hz)" bash -c 'fdtget "$1" /dsi@ff450000/panel@0 panel_description | grep -q "clock=31080 horizontal=640,150,60,150 vertical=480,20,6,12 default=1"' _ "$DTB"

echo "-- sistema"
mcopy -n -i "$FAT" ::boot/batocera "$TMP/system.squashfs" 2>/dev/null
mcopy -n -i "$FAT" ::boot/rufomaculata "$TMP/rufo.squashfs" 2>/dev/null
SQ="$TMP/system.squashfs"
RUFO="$TMP/rufo.squashfs"
# l'elenco dei file del sistema intero: i due squashfs insieme
LIST="$TMP/list"
{ unsquashfs -l -d '' "$SQ"; unsquashfs -l -d '' "$RUFO"; } > "$LIST" 2>/dev/null || true
has() { grep -qE "$1" "$LIST"; }
cat_sq() { unsquashfs -cat "$SQ" "$1" 2>/dev/null || unsquashfs -cat "$RUFO" "$1" 2>/dev/null; }
chk "modulo rocknix-singleadc-joypad" has '/lib/modules/[^/]+/.*/rocknix-singleadc-joypad\.ko(\.[a-z]+)?$'
chk "modulo rk915" has '/lib/modules/[^/]+/.*/rk915\.ko(\.[a-z]+)?$'
chk "firmware RK915 (rk915_fw.bin, rk915_patch.bin)" bash -c 'grep -qE "/lib/firmware/rk915_fw\.bin$" "$1" && grep -qE "/lib/firmware/rk915_patch\.bin$" "$1"' _ "$LIST"
chk "modprobe.d: rk915 caricato dal nodo rockchip,rk915" \
	bash -c '[ "$(unsquashfs -cat "$1" /etc/modprobe.d/rk915.conf 2>/dev/null | grep -v "^#")" = "alias of:N*T*Crockchip,rk915* rk915" ]' _ "$SQ"
JOY="$(grep -E '/lib/modules/[^/]+/.*/rocknix-singleadc-joypad\.ko' "$LIST" | head -1)"
if [ -n "$JOY" ]; then
	cat_sq "$JOY" > "$TMP/joy.ko"
	case "$JOY" in *.xz) xz -dc "$TMP/joy.ko" > "$TMP/joy.raw" ;; *.zst) zstd -qdc "$TMP/joy.ko" > "$TMP/joy.raw" ;; *.gz) gzip -dc "$TMP/joy.ko" > "$TMP/joy.raw" ;; *) cp "$TMP/joy.ko" "$TMP/joy.raw" ;; esac
	chk "joypad con la patch del motore su GPIO" grep -qa 'rumble setup success (gpio)' "$TMP/joy.raw"
else
	bad "joypad con la patch del motore su GPIO (modulo assente)"
fi
chk "es_input.cfg: XiFan RF35H Gamepad, hotkey Select" \
	bash -c 'cat_in() { unsquashfs -cat "$1" "$2" 2>/dev/null; }; cfg="$(cat_in "$1" /usr/share/emulationstation/es_input.cfg)"; blk="$(sed -n "/deviceName=\"XiFan RF35H Gamepad\" deviceGUID=\"190000004b4800003511000000010000\"/,/<\/inputConfig>/p" <<<"$cfg")"; grep -q "name=\"hotkey\" type=\"button\" id=\"8\" value=\"1\" code=\"314\"" <<<"$blk"' _ "$SQ"
cat_sq /usr/bin/emulationstation > "$TMP/es.bin"
chk "emulationstation: gli aggiornamenti usano il batocera-upgrade dell'immagine (fork/0004)" \
	bash -c '[ -s "$1" ] && ! grep -qa "batocera.linux/raw/refs/heads/master/package/batocera/core/batocera-scripts/scripts/batocera-upgrade" "$1"' _ "$TMP/es.bin"
UPG="$(cat_sq /usr/bin/batocera-upgrade)"
chk "batocera-upgrade: aggiornamenti dalle release GitHub" grep -qE '^G_UPDATEURL="https://github\.com/[^/]+/[^/]+/releases/latest/download"$' <<<"$UPG"
chk "batocera-upgrade: controllo della board anche dalla rete" grep -q 'the URL no longer names the board' <<<"$UPG"
VER="$(cat_sq /usr/share/batocera/batocera.version)"
chk "batocera.version col nome rf35h ($VER)" grep -q -- '-rf35h-' <<<"$VER"
chk "batocera.version al massimo 48 caratteri (${#VER}: EmulationStation scarta le piu' lunghe)" test "${#VER}" -le 48
NCORES="$(grep -cE '/usr/lib/libretro/[^/]+_libretro\.so$' "$LIST")"
chk "core libretro: $NCORES, con gambatte, snes9x, mgba, fbneo, mame078plus, pcsx_rearmed, flycastvl" \
	bash -c 'for c in gambatte snes9x mgba fbneo mame078plus pcsx_rearmed flycastvl; do grep -qE "/usr/lib/libretro/${c}_libretro\.so$" "$1" || exit 1; done' _ "$LIST"
chk "profilo snello: niente Kodi, MAME attuale, Moonlight" \
	bash -c '! grep -qE "/usr/(bin|lib)/(kodi|mame|moonlight-qt)(/|$)" "$1" && ! grep -qE "/usr/lib/libretro/mame_libretro\.so$" "$1"' _ "$LIST"

echo "-- aggiornamento"
BT="$DIR/boot.tar.xz"
if [ -f "$BT" ]; then
	chk "boot.tar.xz.md5" bash -c '[ "$(cat "$1.md5")" = "$(md5sum "$1" | cut -d" " -f1)" ]' _ "$BT"
	chk "boot.tar.xz: board rf35h" bash -c '[ "$(tar -xJf "$1" boot/batocera.board -O | tr -d "\n ")" = rf35h ]' _ "$BT"
	chk "boot.tar.xz: i due squashfs (.update), DTB, boot.scr, extlinux.conf" \
		bash -c 'l="$(tar -tJf "$1")"; for f in boot/batocera.update boot/rufomaculata.update rk3326-xifan-rf35h.dtb boot.scr extlinux/extlinux.conf linux initrd.lz4; do grep -qx "$f" <<<"$l" || exit 1; done' _ "$BT"
	chk "boot.tar.xz: niente loader SPI o da riscrivere" \
		bash -c '! tar -tJf "$1" | grep -qE "u-boot-rockchip-spi\.bin|rkspi_loader\.img|u-boot-sunxi-with-spl\.bin"' _ "$BT"
	chk "batocera.version accanto (uguale a quella del sistema)" bash -c '[ "$(cat "$1")" = "$2" ]' _ "$DIR/batocera.version" "$VER"
else
	bad "boot.tar.xz assente"
fi

echo
if [ "$FAIL" -eq 0 ]; then
	echo "Conforme"
	exit 0
fi
echo "NON conforme: $FAIL controlli falliti"
exit 1
