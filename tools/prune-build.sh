#!/bin/bash
# prune-build.sh - toglie i file di compilazione dei pacchetti gia' finiti.
#
#   tools/prune-build.sh [-n] OUTPUT
#
# OUTPUT e' la cartella di Buildroot (quella con build/, host/, target/;
# per tools/build.sh: WORK/output/rf35h). -n elenca soltanto.
#
# Un pacchetto e' finito quando la sua cartella in build/ ha .stamp_installed,
# l'ultimo stamp di Buildroot (dopo host, staging, target e images). Da li' in
# poi quello che serve agli altri pacchetti sta in host/, target/, staging e
# images/; i suoi oggetti no. Se ne tengono gli stamp e gli altri file nascosti
# alla radice della cartella (.files-list*): make vede gli stamp e non lo
# ricostruisce, come se la cartella fosse intatta.
#
# Restano intere le cartelle che si leggono anche dopo l'installazione:
#   linux                 i moduli esterni compilano contro il suo albero
#                         (rk915, rocknix-joypad, ...), e target-finalize
#                         ne chiede la versione (LINUX_RUN_DEPMOD)
#   python3               target-finalize compila i .pyc con il suo
#                         Lib/compileall.py (BR2_PACKAGE_PYTHON3_PY_PYC), e
#                         i pacchetti python con estensioni C lo usano come
#                         _PYTHON_PROJECT_BASE (senza, si compilerebbero con
#                         gli header di python dell'host)
#   alllinuxfirmwares     batocera-initramfs ne copia i firmware
#   wireless-regdb        batocera-initramfs ne copia il database
# Cercato nei .mk di Batocera e di buildroot, infrastruttura e hook di
# target-finalize compresi: nient'altro legge una cartella di build dopo
# l'installazione. Un pacchetto non finito non si tocca mai.
#
# Serve alla CI: lo stato passato da una parte all'altra e' molto piu' piccolo,
# e il disco del runner non si riempie. Si puo' usare anche a mano; un
# pacchetto potato si ricostruisce con "<pacchetto>-dirclean" e una build.
set -euo pipefail

DRY=no
if [ "${1:-}" = "-n" ]; then DRY=yes; shift; fi
OUT="${1:?uso: prune-build.sh [-n] OUTPUT}"
BUILD="$OUT/build"
[ -d "$BUILD" ] || { echo "prune: $BUILD non esiste" >&2; exit 1; }

# nome-versione esatto: linux-headers, linux-pam, python3-configobj non c'entrano
KEEP_RE='^(linux|python3|alllinuxfirmwares|wireless-regdb)-[0-9][0-9.]*$'

n=0; skipped=0
before=$(du -sk "$BUILD" 2>/dev/null | cut -f1)
for d in "$BUILD"/*/; do
	d="${d%/}"; name="$(basename "$d")"
	[ -f "$d/.stamp_installed" ] || continue
	if [[ "$name" =~ $KEEP_RE ]]; then skipped=$((skipped + 1)); continue; fi
	# gia' potato: solo file nascosti alla radice
	if [ -z "$(find "$d" -mindepth 1 -maxdepth 1 ! -name '.*' -print -quit)" ] \
	   && [ -z "$(find "$d" -mindepth 1 -maxdepth 1 -name '.*' -type d -print -quit)" ]; then
		continue
	fi
	n=$((n + 1))
	if [ "$DRY" = yes ]; then
		echo "$name"
	else
		find "$d" -mindepth 1 -maxdepth 1 \( ! -name '.*' -o -type d \) -exec rm -rf {} +
	fi
done
after=$(du -sk "$BUILD" 2>/dev/null | cut -f1)
echo "prune: $n pacchetti potati, $skipped tenuti interi; build/ da $((before / 1024)) a $((after / 1024)) MB"
