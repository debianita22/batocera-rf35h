#!/bin/bash
# test-upgrade.sh - batocera-upgrade (con fork/0002) in una sandbox.
#
#   tools/test-upgrade.sh BATOCERA_TREE
#
# Prende batocera-upgrade dall'albero preparato da tools/apply.sh, ne sposta i
# percorsi assoluti (/boot, /userdata, /usr/...) in una cartella temporanea e
# sostituisce rete e sistema con finti: curl e wget servono i file di una
# "release" locale per gli URL di GitHub, e annotano ogni URL chiesto; mount,
# sync e sleep non fanno niente. Poi le stesse chiamate che fa EmulationStation:
#
#   --check-upgrade   versione diversa -> la stampa ed esce 0; uguale -> 12;
#                     l'URL chiesto e' .../releases/latest/download/batocera.version
#   --upgrade         scarica boot.tar.xz e la .md5 dalla release, li verifica,
#                     controlla la board nell'archivio, estrae in /boot
#   board sbagliata   (un boot.tar.xz rk3326) -> errore, /boot intatto
#   md5 sbagliata     -> errore, /boot intatto
#   updates.url di Batocera -> URL con board e tipo, come prima della patch
set -euo pipefail

TREE="${1:?uso: test-upgrade.sh BATOCERA_TREE}"
SRC="$TREE/package/batocera/core/batocera-scripts/scripts/batocera-upgrade"
[ -f "$SRC" ] || { echo "test-upgrade: $SRC non esiste" >&2; exit 2; }
URL="$(sed -n 's/^G_UPDATEURL="\(.*\)"$/\1/p' "$SRC")"
case "$URL" in
	https://github.com/*/releases/latest/download) ;;
	*) echo "test-upgrade: G_UPDATEURL non e' una release GitHub ($URL): apply.sh non e' stato fatto?" >&2; exit 2 ;;
esac

W="$(mktemp -d "${TMPDIR:-/tmp}/rf35h-tup.XXXXXX")"
trap 'rm -rf "$W"' EXIT
SB="$W/sb"; SRV="$W/release"; BIN="$W/bin"; LOG="$W/urls.log"

pass=0; fail=0
ok()  { echo "  ok  $*"; pass=$((pass + 1)); }
bad() { echo "  NO  $*"; fail=$((fail + 1)); }

# --- lo script, coi percorsi dentro la sandbox --------------------------------
# /boot solo dove comincia un percorso: "/boot/boot/..." e' un percorso solo
python3 - "$SRC" "$W/batocera-upgrade" "$SB" "$BIN" <<'PYEOF'
import re, sys
src, dst, sb, binp = sys.argv[1:5]
s = open(src).read()
s = s.replace('/userdata/system', sb + '/userdata/system')
s = s.replace('/usr/share/batocera/batocera.version', sb + '/usr/share/batocera/batocera.version')
s = s.replace('/usr/bin/batocera-settings-get', binp + '/batocera-settings-get')
s = s.replace('/usr/bin/updateabl', sb + '/usr/bin/updateabl')
s = re.sub(r'(?<![\w/.$}-])/boot\b', sb + '/boot', s)
open(dst, 'w').write(s)
PYEOF
chmod +x "$W/batocera-upgrade"
grep -q "$SB/boot/boot/batocera.board" "$W/batocera-upgrade" || { echo "test-upgrade: percorsi non spostati" >&2; exit 2; }

# --- comandi finti --------------------------------------------------------------
mkdir -p "$BIN"
cat > "$BIN/curl" <<EOF
#!/bin/bash
# curl finto: -I (intestazioni) o -o FILE, per gli URL della release finta
out=""; head=no; url=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-o) out="\$2"; shift 2 ;;
		-A) shift 2 ;;
		-*I*) head=yes; shift ;;
		-*) shift ;;
		*) url="\$1"; shift ;;
	esac
done
echo "curl \$url" >> "$LOG"
case "\$url" in
	$URL/*) f="$SRV/\${url#$URL/}" ;;
	*) exit 22 ;;
esac
[ -f "\$f" ] || exit 22
if [ "\$head" = yes ]; then
	printf 'HTTP/2 302\r\nlocation: https://objects.example/x\r\n\r\nHTTP/2 200\r\nContent-Length: %s\r\n\r\n' "\$(stat -c%s "\$f")"
elif [ -n "\$out" ]; then
	cp "\$f" "\$out"
else
	cat "\$f"
fi
EOF
cat > "$BIN/wget" <<EOF
#!/bin/bash
url="\${@: -1}"
echo "wget \$url" >> "$LOG"
case "\$url" in
	$URL/*) f="$SRV/\${url#$URL/}" ;;
	*) exit 8 ;;
esac
[ -f "\$f" ] && cat "\$f" || exit 8
EOF
cat > "$BIN/batocera-settings-get" <<EOF
#!/bin/bash
case "\$1" in
	updates.url) [ -f "$W/updates.url" ] && cat "$W/updates.url" ;;
	updates.type) echo stable ;;
esac
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "$BIN/mount"
printf '#!/bin/bash\nexit 0\n' > "$BIN/sync"
printf '#!/bin/bash\nexec /bin/sleep 0.01\n' > "$BIN/sleep"
printf '#!/bin/bash\necho extra\n' > "$BIN/batocera-version"
chmod +x "$BIN"/*

# --- una release finta e una console finta -------------------------------------
release() {	# $1 board nell'archivio, $2 versione
	rm -rf "$SRV" "$W/new"; mkdir -p "$SRV" "$W/new/boot"
	echo "$1" > "$W/new/boot/batocera.board"
	echo "system $2" > "$W/new/boot/batocera.update"
	echo kernel-new > "$W/new/linux"
	(cd "$W/new" && tar -cJf "$SRV/boot.tar.xz" -- *)
	md5sum "$SRV/boot.tar.xz" | cut -d' ' -f1 > "$SRV/boot.tar.xz.md5"
	echo "$2" > "$SRV/batocera.version"
}
console() {	# lo stato della console prima di ogni prova
	rm -rf "$SB" "$LOG" "$W/updates.url"; : > "$LOG"
	mkdir -p "$SB/boot/boot" "$SB/userdata/system/upgrade" "$SB/usr/share/batocera"
	echo rf35h > "$SB/boot/boot/batocera.board"
	echo "system old" > "$SB/boot/boot/batocera"
	echo kernel-old > "$SB/boot/linux"
	echo "44-dev-rf35h-v1.0.0 2026/10/04 18:00" > "$SB/usr/share/batocera/batocera.version"
}
run() { PATH="$BIN:$PATH" "$W/batocera-upgrade" "$@" > "$W/out.log" 2>&1 < /dev/null; }

echo "==> controllo dell'aggiornamento (come EmulationStation)"
console; release rf35h "44-dev-rf35h-v1.0.1 2026/10/10 12:00"
rc=0; run --check-upgrade || rc=$?
if [ "$rc" = 0 ] && grep -qx "44-dev-rf35h-v1.0.1 2026/10/10 12:00" "$W/out.log"; then ok "versione nuova: la stampa, esce 0"; else bad "versione nuova: esce $rc"; sed 's/^/      /' "$W/out.log"; fi
if grep -qx "wget $URL/batocera.version" "$LOG"; then ok "chiede $URL/batocera.version"; else bad "URL del controllo:"; sed 's/^/      /' "$LOG"; fi
console; release rf35h "44-dev-rf35h-v1.0.0 2026/10/04 18:00"
rc=0; run --check-upgrade || rc=$?
if [ "$rc" = 12 ]; then ok "stessa versione: esce 12"; else bad "stessa versione: esce $rc"; fi
# il limite di build.yml e build.sh (18 caratteri di versione) contro quello
# dello script: EmulationStation scarta una batocera.version di 49 o piu'
console; release rf35h "44-dev-rf35h-$(printf 'x%.0s' $(seq 18)) 2026/10/10 12:00"
rc=0; run --check-upgrade || rc=$?
if [ "$rc" = 0 ]; then ok "versione di 18 caratteri (48 in tutto): proposta"; else bad "versione di 18 caratteri: esce $rc"; fi
console; release rf35h "44-dev-rf35h-$(printf 'x%.0s' $(seq 19)) 2026/10/10 12:00"
rc=0; run --check-upgrade || rc=$?
if [ "$rc" = 2 ]; then ok "versione di 19 caratteri (49 in tutto): scartata, come dice build.yml"; else bad "versione di 19 caratteri: esce $rc (il limite di 18 non e' piu' quello giusto)"; fi

echo "==> aggiornamento"
console; release rf35h "44-dev-rf35h-v1.0.1 2026/10/10 12:00"
rc=0; run --upgrade || rc=$?
if [ "$rc" = 0 ] && grep -qx "system 44-dev-rf35h-v1.0.1 2026/10/10 12:00" "$SB/boot/boot/batocera.update" \
   && grep -qx kernel-new "$SB/boot/linux"; then
	ok "boot.tar.xz scaricato, verificato ed estratto in /boot"
else
	bad "aggiornamento: esce $rc"; sed 's/^/      /' "$W/out.log"
fi
if grep -qx "curl $URL/boot.tar.xz" "$LOG" && grep -qx "curl $URL/boot.tar.xz.md5" "$LOG"; then ok "file presi dalla radice della release"; else bad "URL dello scaricamento:"; sed 's/^/      /' "$LOG"; fi

console; release rk3326 "44-dev-rf35h-v1.0.1 2026/10/10 12:00"
rc=0; run --upgrade || rc=$?
if [ "$rc" != 0 ] && [ ! -e "$SB/boot/boot/batocera.update" ] && grep -qx kernel-old "$SB/boot/linux"; then
	ok "archivio di un'altra board (rk3326): rifiutato, /boot intatto"
else
	bad "archivio di un'altra board: esce $rc"; sed 's/^/      /' "$W/out.log"
fi

console; release rf35h "44-dev-rf35h-v1.0.1 2026/10/10 12:00"; echo 0123 > "$SRV/boot.tar.xz.md5"
rc=0; run --upgrade || rc=$?
if [ "$rc" != 0 ] && [ ! -e "$SB/boot/boot/batocera.update" ]; then ok "md5 sbagliata: rifiutato, /boot intatto"; else bad "md5 sbagliata: esce $rc"; fi

echo "==> updates.url di Batocera: come prima della patch"
console; release rf35h "x"; echo "https://updates.batocera.org" > "$W/updates.url"
run --check-upgrade || true
if grep -qx "wget https://updates.batocera.org/rf35h/stable/last/batocera.version" "$LOG"; then ok "controllo su .../rf35h/stable/last"; else bad "controllo:"; sed 's/^/      /' "$LOG"; fi
console; echo "https://updates.batocera.org" > "$W/updates.url"
run --check-upgrade butterfly || true
if grep -qx "wget https://updates.batocera.org/rf35h/butterfly/last/batocera.version" "$LOG"; then ok "controllo butterfly su .../rf35h/butterfly/last"; else bad "controllo butterfly:"; sed 's/^/      /' "$LOG"; fi
console; echo "https://updates.batocera.org" > "$W/updates.url"
rc=0; run --upgrade || rc=$?
if [ "$rc" != 0 ] && grep -qx "curl https://updates.batocera.org/rf35h/stable/last/boot.tar.xz" "$LOG"; then ok "scaricamento da .../rf35h/stable/last"; else bad "scaricamento: esce $rc"; sed 's/^/      /' "$LOG"; fi

echo
echo "test-upgrade: $pass ok, $fail falliti"
[ "$fail" -eq 0 ]
