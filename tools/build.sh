#!/bin/bash
# build.sh - Batocera per la XiFan RF35H, nel container di build di Batocera.
#
#   tools/build.sh [--tree DIR] [--work DIR] [--version V] [--no-apply] [ARG...]
#
#   --tree DIR   l'albero di Batocera (predefinita: batocera.linux accanto a
#                questo repo); tools/apply.sh lo prepara, a meno di --no-apply
#   --work DIR   output/, dl/ e ccache/ (predefinita: batocera-rf35h-build
#                accanto a questo repo); fuori dall'albero apposta: apply.sh
#                lo riporta al commit fissato senza toccare niente di costruito
#   --version V  il nome nella versione di Batocera; senza, l'overlay
#                (commit corto di questo repo, "-dirty" se ha modifiche)
#   ARG...       passati a make, dopo il target (per esempio linux-rebuild)
#
# Usa il Makefile di Batocera, cioe' il suo container (batoceralinux/
# batocera.linux-build, scaricato da Docker Hub alla prima build), la sua
# configurazione del target "rf35h" (configs/batocera-rf35h.board, creato da
# fork/) e la sua ccache. Il container si chiama RF35H_CONTAINER (predefinito
# rf35h-build): la CI lo ferma con docker kill.
#
# La versione e' quella di Batocera piu' la nostra:
#     44-dev-<commit di Batocera>.rf35h-<V> AAAA/MM/GG hh:mm
# ed e' cio' che le console confrontano con batocera.version dell'ultima
# release per proporre l'aggiornamento.
#
# Le immagini finiscono in WORK/output/rf35h/images/batocera/images/:
#     rf35h/     la nostra (loader known-good), boot.tar.xz e batocera.version
#     mainline/  quella di Batocera, per provare la serie upstream
#
# Buildroot non ricostruisce da solo un pacchetto gia' costruito quando ne
# cambiano il .mk o le patch: dopo aver cambiato upstream/ o fork/, sul lavoro
# gia' fatto serve "tools/build.sh <pacchetto>-dirclean" (per il DTS:
# linux-rebuild), poi una build normale.
set -euo pipefail

O="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$(dirname "$O")/batocera.linux"
WORK="$(dirname "$O")/batocera-rf35h-build"
VERSION=""
APPLY=yes
while [ $# -gt 0 ]; do
	case "$1" in
		--tree) TREE="$2"; shift 2 ;;
		--work) WORK="$2"; shift 2 ;;
		--version) VERSION="$2"; shift 2 ;;
		--no-apply) APPLY=no; shift ;;
		-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
		--) shift; break ;;
		-*) echo "build: opzione sconosciuta: $1" >&2; exit 2 ;;
		*) break ;;
	esac
done

die() { printf 'build: %s\n' "$*" >&2; exit 1; }

case "$VERSION" in
	*[!A-Za-z0-9._+-]*) die "--version '$VERSION': solo lettere, cifre e . _ + -" ;;
esac

if [ "$APPLY" = yes ]; then
	"$O/tools/apply.sh" --tree "$TREE"
fi
[ -f "$TREE/.rf35h-overlay" ] || die "$TREE non e' preparato: tools/apply.sh --tree $TREE"
# shellcheck disable=SC1091
. "$TREE/.rf35h-overlay"
[ "$(git -C "$TREE" rev-parse HEAD)" = "${TREE_HEAD:-}" ] \
	|| die "$TREE e' cambiato dopo apply.sh: rifallo (tools/apply.sh --tree $TREE)"
[ -f "$TREE/configs/batocera-rf35h.board" ] || die "$TREE: manca configs/batocera-rf35h.board"

mkdir -p "$WORK/output" "$WORK/dl" "$WORK/ccache"
WORK="$(cd "$WORK" && pwd)"

VER_ID="${BATOCERA_COMMIT:0:7}.rf35h-${VERSION:-${OVERLAY:-nogit}}"
echo "==> Batocera rf35h ${VER_ID} (lavoro in $WORK)"

# make di Batocera: BATCH_MODE niente terminale interattivo; GIT_COMMIT va
# nella versione (batocera-system.mk); le cartelle fuori dall'albero.
exec make -C "$TREE" rf35h-build BATCH_MODE=1 \
	OUTPUT_DIR="$WORK/output" DL_DIR="$WORK/dl" CCACHE_DIR="$WORK/ccache" \
	GIT_COMMIT="$VER_ID" \
	DOCKER_OPTS="--name ${RF35H_CONTAINER:-rf35h-build} -e CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-6G}" \
	${1:+CMD="$*"}
