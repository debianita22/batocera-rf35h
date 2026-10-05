#!/bin/bash
# test-ci-build.sh - i passi di ci-build.sh che in CI girano solo dopo ore.
#
#   tools/test-ci-build.sh BATOCERA_TREE [DTB]
#
# Senza docker e senza build: una cartella di buildroot finta, con pacchetti
# finiti, uno interrotto e quelli che la potatura deve lasciare interi, e
#
#   pack + unpack   lo stato passa da una parte all'altra: i pacchetti finiti
#                   potati (restano gli stamp), linux intero, il pacchetto
#                   interrotto tolto (si rifa' da capo), ccache e digest del
#                   container portati
#   rebuild         RF35H_REBUILD toglie la cartella build/<nome>-<versione>;
#                   un nome che non e' un pacchetto ferma tutto
#   collect         con DTB (rk3326-xifan-rf35h.dtb compilato): un'immagine
#                   finta giusta -> file della release in dist, verdict passa;
#                   un'immagine rotta -> collect non fallisce, i file ci sono
#                   lo stesso (vanno caricati), verdict fallisce
set -euo pipefail

TREE="${1:?uso: test-ci-build.sh BATOCERA_TREE [DTB]}"
DTB="${2:-}"
O="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/rf35h-tcb.XXXXXX")"
trap 'rm -rf "$T"' EXIT

pass=0; fail=0
ok()  { echo "  ok  $*"; pass=$((pass + 1)); }
bad() { echo "  NO  $*"; fail=$((fail + 1)); }
ci()  { env -u GITHUB_ACTIONS W="$T/w" RF35H_STAGE=1 "$@"; }

fake_tree() {
	local b="$T/w/work/output/rf35h/build"
	rm -rf "$T/w"; mkdir -p "$b" "$T/w/work/ccache"
	pkg() {	# nome-versione, stamp...
		local d="$b/$1"; shift
		mkdir -p "$d/src/.deps"; echo obj > "$d/src/a.o"; echo mk > "$d/Makefile"
		echo list > "$d/.files-list.txt"
		local s; for s in "$@"; do touch "$d/.stamp_$s"; done
	}
	local all=(downloaded extracted patched configured built target_installed installed)
	pkg foo-1.0 "${all[@]}"
	pkg host-baz-3 downloaded extracted patched configured built host_installed installed
	pkg linux-7.2.8 "${all[@]}"
	pkg python3-3.14.5 "${all[@]}"
	pkg linux-headers-7.2.8 "${all[@]}"
	pkg python3-configobj-5.0.8 "${all[@]}"
	pkg bar-2.0 downloaded extracted patched configured
	pkg qux-0.1 downloaded extracted
	pkg configgen-local rsynced configured built
	mkdir -p "$b/buildroot-config"; echo conf > "$b/buildroot-config/auto.conf"
	mkdir -p "$T/w/work/output/rf35h/host/bin"; echo gcc > "$T/w/work/output/rf35h/host/bin/gcc"
	echo cache > "$T/w/work/ccache/entry"
	echo "batoceralinux/batocera.linux-build@sha256:0123" > "$T/w/work/container.txt"
	printf '%s\n' "bar 2.0" "foo 1.0" "host-baz 3" "linux 7.2.8" "python3 3.14.5" "linux-headers 7.2.8" "python3-configobj 5.0.8" "qux 0.1" "configgen local" > "$T/w/packages.txt"
}

echo "==> pack e unpack"
fake_tree
ci "$O/tools/ci-build.sh" pack 1 > "$T/pack.log" 2>&1 || { cat "$T/pack.log"; exit 1; }
[ -s "$T/w/state-1.tar.zst" ] && ok "state-1.tar.zst" || bad "state-1.tar.zst assente"
mkdir -p "$T/w/dl-state"; mv "$T/w/state-1.tar.zst" "$T/w/dl-state/"
pk="$(cat "$T/w/packages.txt")"
rm -rf "$T/w/work"
ci "$O/tools/ci-build.sh" unpack 1 > "$T/unpack.log" 2>&1 || { cat "$T/unpack.log"; exit 1; }
b="$T/w/work/output/rf35h/build"
[ -f "$b/foo-1.0/.stamp_installed" ] && [ -f "$b/foo-1.0/.files-list.txt" ] && [ ! -e "$b/foo-1.0/src" ] && [ ! -e "$b/foo-1.0/Makefile" ] \
	&& ok "pacchetto finito potato, stamp e .files-list tenuti" || bad "foo-1.0: $(ls -A "$b/foo-1.0" 2>&1 | tr '\n' ' ')"
[ -f "$b/host-baz-3/.stamp_installed" ] && [ ! -e "$b/host-baz-3/src" ] && ok "pacchetto per l'host potato" || bad "host-baz-3"
[ -f "$b/linux-7.2.8/src/a.o" ] && [ -f "$b/linux-7.2.8/Makefile" ] && ok "linux intero" || bad "linux potato"
[ -f "$b/python3-3.14.5/src/a.o" ] && ok "python3 intero (compileall.py in target-finalize, _PYTHON_PROJECT_BASE)" || bad "python3 potato"
[ ! -e "$b/linux-headers-7.2.8/src" ] && [ ! -e "$b/python3-configobj-5.0.8/src" ] && ok "linux-headers e python3-configobj potati (nome esatto)" || bad "linux-headers o python3-configobj tenuti interi"
[ ! -e "$b/bar-2.0" ] && ok "pacchetto interrotto (configurato, non finito) tolto" || bad "bar-2.0 ancora li'"
[ ! -e "$b/qux-0.1" ] && ok "pacchetto interrotto (estratto) tolto" || bad "qux-0.1 ancora li'"
[ ! -e "$b/configgen-local" ] && ok "pacchetto locale interrotto (rsync) tolto" || bad "configgen-local ancora li'"
[ -f "$b/buildroot-config/auto.conf" ] && ok "buildroot-config non toccato" || bad "buildroot-config"
[ -f "$T/w/work/ccache/entry" ] && ok "ccache portata" || bad "ccache persa"
[ "$(cat "$T/w/work/container.txt" 2>/dev/null)" = "batoceralinux/batocera.linux-build@sha256:0123" ] && ok "digest del container portato" || bad "container.txt"
[ -f "$T/w/work/output/rf35h/host/bin/gcc" ] && ok "host/ portato" || bad "host/"
[ ! -e "$T/w/dl-state/state-1.tar.zst" ] && ok "tarball dello stato tolto dopo l'estrazione" || bad "tarball rimasto"

echo "==> rebuild"
fake_tree
printf '%s\n' "$pk" > "$T/w/packages.txt"
if ( ci env RF35H_REBUILD="foo linux" bash -c '. <(sed -n "/^say()/,/^}/p;/^note()/,/^}/p;/^paths()/,/^}/p;/^rebuild()/,/^}/p;/^die()/p" "$1"); paths; rebuild' _ "$O/tools/ci-build.sh" ) > "$T/rb.log" 2>&1 \
   && [ ! -e "$b/foo-1.0" ] && [ ! -e "$b/linux-7.2.8" ] && [ -e "$b/host-baz-3" ]; then
	ok "RF35H_REBUILD=\"foo linux\": tolti foo-1.0 e linux-7.2.8, host-baz-3 no"
else
	bad "rebuild:"; sed 's/^/      /' "$T/rb.log"
fi
if ( ci env RF35H_REBUILD="nonesiste" bash -c '. <(sed -n "/^say()/,/^}/p;/^note()/,/^}/p;/^paths()/,/^}/p;/^rebuild()/,/^}/p;/^die()/p" "$1"); paths; rebuild' _ "$O/tools/ci-build.sh" ) > "$T/rb2.log" 2>&1; then
	bad "un pacchetto inesistente in RF35H_REBUILD non ferma"
else
	ok "un pacchetto inesistente in RF35H_REBUILD ferma tutto"
fi

if [ -n "$DTB" ]; then
	echo "==> collect e verdict"
	for case in good loader-flip; do
		fake_tree
		img="$T/w/work/output/rf35h/images/batocera/images"
		mut=""; [ "$case" = good ] || mut="$case"
		"$O/tools/test-verify-image.sh" --make-image "$TREE" "$DTB" "$img/rf35h" "$mut"
		mkdir -p "$img/mainline"
		echo img | gzip > "$img/mainline/batocera-rk3326-mainline-44-20261005.img.gz"
		cp "$img/rf35h/batocera.version" "$img/mainline/"
		rc=0; ci "$O/tools/ci-build.sh" collect > "$T/collect.log" 2>&1 || rc=$?
		files=$(cd "$T/w/dist" 2>/dev/null && ls | tr '\n' ' ')
		vrc=0; ci "$O/tools/ci-build.sh" verdict > "$T/verdict.log" 2>&1 || vrc=$?
		if [ "$rc" = 0 ] && [ -f "$T/w/dist/boot.tar.xz" ] && ls "$T/w/dist"/batocera-rk3326-rf35h-*.img.gz >/dev/null 2>&1 \
		   && [ -f "$T/w/dist/SHA256SUMS" ] && [ -f "$T/w/dist/verify-image.txt" ] && [ -f "$T/w/upstream/batocera.version" ]; then
			ok "$case: collect esce 0, file in dist ($files) e upstream"
		else
			bad "$case: collect esce $rc, dist: $files"; tail -5 "$T/collect.log" | sed 's/^/      /'
		fi
		if [ "$case" = good ]; then
			[ "$vrc" = 0 ] && ok "good: verdict passa" || { bad "good: verdict fallisce"; sed 's/^/      /' "$T/verdict.log"; }
		else
			[ "$vrc" != 0 ] && grep -q 'verify-image' "$T/verdict.log" && ok "$case: verdict fallisce (verify-image)" || bad "$case: verdict passa"
		fi
	done
fi

echo
echo "test-ci-build: $pass ok, $fail falliti"
[ "$fail" -eq 0 ]
