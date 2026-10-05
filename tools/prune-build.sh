#!/bin/bash
# prune-build.sh - toglie i file di compilazione dei pacchetti gia' finiti.
#
#   tools/prune-build.sh [-n] OUTPUT
#   tools/prune-build.sh -r OUTPUT
#
# OUTPUT e' la cartella di Buildroot (quella con build/, host/, target/;
# per tools/build.sh: WORK/output/rf35h). -n elenca soltanto. -r elenca
# soltanto i pacchetti a cui altri file rimandano (vedi sotto).
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
# e quelle a cui rimanda un file di host/ (sysroot compreso): i .la di
# libtool, i .pc, i .cmake e gli script *-config possono contenere il
# percorso della cartella di build di un pacchetto (dependency_libs di
# libmount.la rimanda a build/util-linux-*/libblkid.la: buildroot sistema
# i percorsi /usr, non questi), e chi li usa dopo lo cerca li' (nfs-utils:
# "cannot find the library .../build/util-linux-2.41.4/libblkid.la").
# Cercato nei .mk di Batocera e di buildroot, infrastruttura e hook di
# target-finalize compresi: nient'altro legge una cartella di build dopo
# l'installazione. Un pacchetto non finito non si tocca mai.
#
# Serve alla CI: lo stato passato da una parte all'altra e' molto piu' piccolo,
# e il disco del runner non si riempie. Si puo' usare anche a mano; un
# pacchetto potato si ricostruisce con "<pacchetto>-dirclean" e una build.
set -euo pipefail

DRY=no; LIST=no
case "${1:-}" in
	-n) DRY=yes; shift ;;
	-r) LIST=yes; shift ;;
esac
OUT="${1:?uso: prune-build.sh [-n|-r] OUTPUT}"
BUILD="$OUT/build"
[ -d "$BUILD" ] || { echo "prune: $BUILD non esiste" >&2; exit 1; }

# nome-versione esatto: linux-headers, linux-pam, python3-configobj non c'entrano
KEEP_RE='^(linux|python3|alllinuxfirmwares|wireless-regdb)-[0-9][0-9.]*$'

# le cartelle di build a cui rimanda un file di host/ (dentro al container il
# percorso e' un altro, /rf35h/build/...: conta solo il nome dopo /build/)
referenced() {
	[ -d "$OUT/host" ] || return 0
	find "$OUT/host" -type f \( -name '*.la' -o -name '*.pc' -o -name '*.cmake' -o -name '*.prl' -o -name '*-config' \) -print0 2>/dev/null \
		| xargs -0 -r grep -ahoE "/build/[^/'\"[:space:]]+/" 2>/dev/null \
		| sed -E 's|^/build/||; s|/$||' | sort -u
}
mapfile -t REFD < <(referenced)
if [ "$LIST" = yes ]; then
	[ "${#REFD[@]}" -eq 0 ] || printf '%s\n' "${REFD[@]}"
	exit 0
fi
is_referenced() { local r; for r in "${REFD[@]}"; do [ "$r" = "$1" ] && return 0; done; return 1; }

n=0; skipped=0
before=$(du -sk "$BUILD" 2>/dev/null | cut -f1)
for d in "$BUILD"/*/; do
	d="${d%/}"; name="$(basename "$d")"
	[ -f "$d/.stamp_installed" ] || continue
	if [[ "$name" =~ $KEEP_RE ]]; then skipped=$((skipped + 1)); continue; fi
	if is_referenced "$name"; then skipped=$((skipped + 1)); continue; fi
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
