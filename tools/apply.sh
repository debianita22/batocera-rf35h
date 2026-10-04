#!/bin/bash
# apply.sh - l'albero di Batocera al commit fissato, con le patch di questo repo.
#
#   tools/apply.sh [--tree DIR]
#
# DIR (predefinita: batocera.linux accanto a questo repo) diventa Batocera al
# commit di batocera.pin, sottomodulo buildroot compreso, piu':
#
#   upstream/*.patch  la serie per batocera.linux (supporto RF35H), con git am
#   fork/*.patch      cio' che resta nostro (immagine rf35h, aggiornamenti dalle
#                     release, profilo snello), con git am
#   il loader         board/loader/known-good.bin in rf35h/loader/, sha256 verificato
#   l'URL             @RF35H_UPDATE_URL@ in batocera-upgrade: le release di
#                     RF35H_UPDATE_REPO (predefinito debianita22/batocera-rf35h)
#
# Ogni volta l'albero torna al commit fissato e le patch si riapplicano da capo:
# il risultato dipende solo da questo repo, date dei file comprese (tutte al
# 1/1/2026, vedi sotto). Il build resta fuori dall'albero
# (tools/build.sh), quindi riportarlo indietro non tocca niente di costruito.
# Le patch applicate con identita' e date fisse danno sempre gli stessi commit:
# lo stesso overlay, lo stesso HEAD.
#
# Buildroot non ricostruisce un pacchetto gia' fatto se cambia il suo .mk o
# una sua patch: dopo aver cambiato le patch, sull'albero gia' costruito si fa
# a mano "<pacchetto>-dirclean" (lo ricorda tools/build.sh).
set -euo pipefail

O="$(cd "$(dirname "$0")/.." && pwd)"
TREE="$(dirname "$O")/batocera.linux"
while [ $# -gt 0 ]; do
	case "$1" in
		--tree) TREE="$2"; shift 2 ;;
		-h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
		*) echo "apply: opzione sconosciuta: $1" >&2; exit 2 ;;
	esac
done

say() { printf '==> %s\n' "$*"; }
die() { printf 'apply: %s\n' "$*" >&2; exit 1; }

# shellcheck source=../batocera.pin
. "$O/batocera.pin"
: "${BATOCERA_URL:?}" "${BATOCERA_COMMIT:?}"
case "$BATOCERA_COMMIT" in
	*[!0-9a-f]*|'') die "BATOCERA_COMMIT in batocera.pin: uno sha completo" ;;
esac
[ "${#BATOCERA_COMMIT}" -eq 40 ] || die "BATOCERA_COMMIT in batocera.pin: uno sha completo (40 caratteri)"

REPO="${RF35H_UPDATE_REPO:-debianita22/batocera-rf35h}"
case "$REPO" in
	*/*) ;;
	*) die "RF35H_UPDATE_REPO: proprietario/nome, non '$REPO'" ;;
esac
UPDATE_URL="https://github.com/${REPO}/releases/latest/download"

LOADER_SHA256="$(cut -d' ' -f1 "$O/board/loader/known-good.sha256")"
[ "$(sha256sum "$O/board/loader/known-good.bin" | cut -d' ' -f1)" = "$LOADER_SHA256" ] \
	|| die "board/loader/known-good.bin non corrisponde a known-good.sha256"

# Gli stessi commit ogni volta: committer fisso, data del committer = data
# dell'autore (--committer-date-is-author-date, sotto).
GIT_ID=(-c user.name="batocera-rf35h" -c user.email="batocera-rf35h@invalid")

say "Batocera ${BATOCERA_COMMIT:0:7} in $TREE"
if [ ! -d "$TREE/.git" ]; then
	mkdir -p "$TREE"
	git -C "$TREE" init -q
	git -C "$TREE" remote add origin "$BATOCERA_URL"
fi
if ! git -C "$TREE" cat-file -e "${BATOCERA_COMMIT}^{commit}" 2>/dev/null; then
	git -C "$TREE" fetch -q --depth 1 origin "$BATOCERA_COMMIT" \
		|| die "il commit $BATOCERA_COMMIT non si scarica da $BATOCERA_URL"
fi
# Le cartelle di build di chi usa il Makefile di Batocera dentro l'albero:
# riportarlo indietro non deve toccarle.
git -C "$TREE" checkout -q --force --detach "$BATOCERA_COMMIT"
git -C "$TREE" clean -q -fdx -e /output -e /dl -e /buildroot-ccache -e /.ba-docker-image-available
git -C "$TREE" submodule -q update --init --depth 1 --force buildroot \
	|| die "il sottomodulo buildroot non si scarica"
git -C "$TREE/buildroot" clean -q -fdx -e /dl

apply_series() {
	local dir="$1" n
	n="$(find "$O/$dir" -maxdepth 1 -name '*.patch' | wc -l)"
	[ "$n" -gt 0 ] || die "$dir/: nessuna patch"
	if ! git "${GIT_ID[@]}" -C "$TREE" am -q --whitespace=nowarn --committer-date-is-author-date --no-3way "$O/$dir"/*.patch; then
		git -C "$TREE" am --abort 2>/dev/null || true
		die "$dir/: una patch non si applica al commit fissato (vedi sopra)"
	fi
	echo "    $dir/: $n patch"
}
say "Patch"
apply_series upstream
apply_series fork

say "Loader e URL degli aggiornamenti"
LDIR="$TREE/board/batocera/rockchip/rk3326/rf35h/loader"
[ -f "$TREE/board/batocera/rockchip/rk3326/rf35h/create-boot-script.sh" ] \
	|| die "manca rk3326/rf35h/create-boot-script.sh: la serie fork/ non l'ha creato"
mkdir -p "$LDIR"
cp "$O/board/loader/known-good.bin" "$LDIR/known-good.bin"
grep -q "LOADER_SHA256=\"$LOADER_SHA256\"" "$TREE/board/batocera/rockchip/rk3326/rf35h/create-boot-script.sh" \
	|| die "lo sha256 del loader in create-boot-script.sh non e' quello di board/loader"

UPG="$TREE/package/batocera/core/batocera-scripts/scripts/batocera-upgrade"
[ "$(grep -c '@RF35H_UPDATE_URL@' "$UPG")" -eq 1 ] \
	|| die "batocera-upgrade: @RF35H_UPDATE_URL@ non c'e' (una volta sola)"
sed -i "s|@RF35H_UPDATE_URL@|${UPDATE_URL}|" "$UPG"
echo "    loader $LOADER_SHA256"
echo "    aggiornamenti da $UPDATE_URL"

# Una data fissa (1/1/2026) su tutti i file dell'albero. Git scrive i file
# con l'ora del checkout, e buildroot riconfigura un pacchetto kconfig (linux,
# batocera-initramfs) quando il file della sua configurazione e' piu' recente
# della .config costruita: senza questo, un albero appena preparato su un
# lavoro gia' fatto (la parte successiva della CI, o apply.sh rifatto a mano)
# rifarebbe kernel e initramfs a ogni volta. Con la data fissa no; e lo stesso
# overlay da' anche le stesse date.
EPOCH=1767225600
(cd "$TREE" && git ls-files -z | xargs -0 touch -h -d "@$EPOCH" --)
(cd "$TREE/buildroot" && git ls-files -z | xargs -0 touch -h -d "@$EPOCH" --)
touch -d "@$EPOCH" "$LDIR/known-good.bin"

# Cosa c'e' nell'albero: lo legge tools/build.sh per il nome della versione e
# per accorgersi di un albero preparato da un altro overlay.
OVERLAY="$(git -C "$O" rev-parse --short=7 HEAD 2>/dev/null || echo nogit)"
if [ -n "$(git -C "$O" status --porcelain -- upstream fork board tools batocera.pin 2>/dev/null)" ]; then
	OVERLAY="${OVERLAY}-dirty"
fi
{
	echo "BATOCERA_COMMIT=$BATOCERA_COMMIT"
	echo "TREE_HEAD=$(git -C "$TREE" rev-parse HEAD)"
	echo "OVERLAY=$OVERLAY"
	echo "UPDATE_URL=$UPDATE_URL"
} > "$TREE/.rf35h-overlay"
say "Pronto: $(git -C "$TREE" rev-parse --short=7 HEAD) (overlay $OVERLAY)"
