#!/bin/bash
# ci-build.sh - i passi della build in CI (.github/workflows/build-stage.yml).
# Fuori dalla CI non serve: a mano si usa tools/build.sh.
#
#   ci-build.sh disk            libera spazio e sceglie il disco piu' grande (W)
#   ci-build.sh prepare         albero di Batocera con le patch (apply.sh),
#                               container di build, elenco dei pacchetti
#   ci-build.sh build           la build, fino alla scadenza del job
#   ci-build.sh pack N [failed] lo stato per la parte N+1 (W/state-N.tar.zst);
#                               "failed": quello di una build fallita, da cui
#                               un'altra build di prova puo' riprendere
#   ci-build.sh unpack N        lo stato della parte N
#   ci-build.sh collect         i file della release in W/dist (con l'esito
#                               di verify-image.sh), l'immagine mainline in
#                               W/upstream; non fallisce: gli artifact si
#                               caricano comunque
#   ci-build.sh verdict         fallisce se collect ha trovato problemi
#   ci-build.sh logs N          i log della parte N (W/log-N.tar.zst)
#   ci-build.sh ccache-stats
#
# Perche' a parti: un job dei runner gratuiti dura al massimo 6 ore e la build
# da zero di Batocera (toolchain, LLVM per host e target, Mesa, kernel, ~850
# pacchetti) ne chiede molte di piu'. Ogni parte costruisce fino a
# BUILD_MINUTES dall'inizio del job; se non ha finito si ferma e la successiva
# riparte dallo stato: buildroot salta i pacchetti che hanno i loro stamp.
#
# Lo stato e' la cartella di buildroot (host, target, images, build), la
# ccache e il digest del container, senza i sorgenti scaricati. Prima di impacchettarlo
# tools/prune-build.sh toglie i file di compilazione dei pacchetti finiti:
# restano gli stamp, e lo stato passa da decine di GB a pochi.
#
# Ripresa: una build di prova puo' partire dallo stato salvato da un run
# fallito (Run workflow, resume_run). RF35H_REBUILD (nomi di pacchetti
# separati da spazi) li fa rifare da capo: buildroot non ricostruisce da solo
# un pacchetto gia' fatto quando ne cambiano il .mk o le patch.
#
# Variabili (le mette il workflow): GITHUB_WORKSPACE, GITHUB_ENV,
# GITHUB_OUTPUT, GITHUB_STEP_SUMMARY, GITHUB_REPOSITORY, JOB_START,
# BUILD_MINUTES, W, RF35H_VERSION, RF35H_CONTAINER, RF35H_STAGE,
# RF35H_REBUILD.
set -euo pipefail

O="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="batoceralinux/batocera.linux-build"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[31m[x] %s\033[0m\n' "$*" >&2; exit 1; }
gb()   { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}'; }
out()  { echo "$1" >> "${GITHUB_OUTPUT:-/dev/null}"; }
summ() { echo "$*" >> "${GITHUB_STEP_SUMMARY:-/dev/null}"; }
# Un'annotazione del job: si legge anche dall'API (check-runs/annotations),
# senza scaricare il log. Righe codificate (%0A); nel titolo anche "," e ":".
note() {
	local level="$1" title="$2" msg="$3"
	[ -n "${GITHUB_ACTIONS:-}" ] || { echo "[$level] $title: $msg"; return 0; }
	msg="${msg//'%'/'%25'}"; msg="${msg//$'\r'/}"; msg="${msg//$'\n'/'%0A'}"
	title="${title//'%'/'%25'}"; title="${title//$'\n'/ }"
	title="${title//:/'%3A'}"; title="${title//,/'%2C'}"
	echo "::${level} title=${title}::${msg}"
}

paths() {
	: "${W:?}"
	TREE="$W/batocera.linux"
	WORKD="$W/work"
	OUT="$WORKD/output/rf35h"
}

cmd_disk() {
	say "Spazio prima"
	df -h / /mnt 2>/dev/null || df -h /
	# Cio' che sul runner c'e' e qui non serve (la build gira nel container).
	# In parallelo: sono decine di GB di file piccoli.
	say "Libero spazio"
	local d
	for d in /usr/local/lib/android /usr/local/.ghcup /opt/ghc /usr/share/dotnet \
	         /usr/share/swift /opt/hostedtoolcache /usr/local/share/powershell \
	         /usr/local/share/chromium /usr/local/lib/node_modules /opt/az \
	         /opt/microsoft /opt/google /usr/lib/jvm /usr/share/java; do
		[ -e "${d}" ] && sudo rm -rf "${d}" &
	done
	docker image prune -af >/dev/null 2>&1 &
	wait
	df -h / /mnt 2>/dev/null || df -h /

	# Il disco con piu' spazio: la build vuole una cartella sola.
	local root mnt=0
	root="$(gb /)"
	if mountpoint -q /mnt 2>/dev/null; then mnt="$(gb /mnt)"; fi
	if [ "${mnt}" -gt "${root}" ]; then
		W=/mnt/rf35h
		sudo mkdir -p "${W}"
		sudo chown "$(id -u):$(id -g)" "${W}"
	else
		W="${HOME}/rf35h"
		mkdir -p "${W}"
	fi
	echo "  cartella di lavoro: ${W} ($(gb "${W}") GB liberi; / ${root} GB, /mnt ${mnt} GB)"
	echo "W=${W}" >> "${GITHUB_ENV:-/dev/null}"
	summ "- disco: ${W}, $(gb "${W}") GB liberi"
	note notice "Disco" "${W}: $(gb "${W}") GB liberi (/ ${root} GB, /mnt ${mnt} GB), $(nproc) CPU, $(free -g | awk '/^Mem:/ {print $2}') GB RAM"
}

cmd_prepare() {
	paths
	say "Batocera con le patch in ${TREE}"
	RF35H_UPDATE_REPO="${GITHUB_REPOSITORY:-debianita22/batocera-rf35h}" "$O/tools/apply.sh" --tree "${TREE}"
	mkdir -p "${WORKD}/output" "${WORKD}/dl" "${WORKD}/ccache"

	say "Container di build"
	# Lo stesso container in tutte le parti: la parte 1 scrive in
	# WORKD/container.txt il digest di quello che ha usato (lo stato lo porta
	# alle parti dopo), che lo riscaricano per digest. Gli strumenti per l'host
	# costruiti in una parte devono girare nel container della parte dopo, e
	# Batocera aggiorna "latest" quando vuole. Se Docker Hub non risponde, il
	# container si costruisce dal Dockerfile del commit fissato.
	local want="" ref digest _
	[ -f "${WORKD}/container.txt" ] && want="$(cat "${WORKD}/container.txt")"
	case "${want}" in
		"${IMAGE}"@sha256:*) ref="${want}" ;;
		built:*|'')         ref="${IMAGE}:latest" ;;
		*) die "WORKD/container.txt: '${want}' non e' un digest di ${IMAGE}" ;;
	esac
	for _ in 1 2 3; do docker pull -q "${ref}" && break; sleep 30; done
	if docker image inspect "${ref}" >/dev/null 2>&1; then
		[ "${ref}" = "${IMAGE}:latest" ] || docker tag "${ref}" "${IMAGE}:latest"
		digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "${IMAGE}:latest")"
	elif [ "${ref}" = "${IMAGE}:latest" ]; then
		note warning "Container" "${IMAGE} non si scarica: lo costruisco da docker/Dockerfile"
		docker build -q -t "${IMAGE}:latest" "${TREE}/docker" >/dev/null || die "${IMAGE}: ne' scaricato ne' costruito"
		digest="built:$(docker image inspect --format '{{.Id}}' "${IMAGE}:latest")"
	else
		die "${ref} (il container delle parti precedenti) non si scarica"
	fi
	[ -n "${want}" ] || echo "${digest}" > "${WORKD}/container.txt"
	# il Makefile di Batocera non lo riscarica se trova questo stamp
	touch "${TREE}/.ba-docker-image-available"
	echo "  ${digest}"

	say "Elenco dei pacchetti"
	local cfg="${W}/cfg"
	rm -rf "${cfg}"; mkdir -p "${cfg}"
	: > "${W}/empty_user_defconfig"
	"${TREE}/configs/createDefconfig.sh" "${TREE}/configs/batocera-rf35h.board" "${W}/empty_user_defconfig" "${TREE}/configs/batocera-rf35h_defconfig"
	make -s -C "${TREE}/buildroot" O="${cfg}" BR2_EXTERNAL="${TREE}" batocera-rf35h_defconfig >/dev/null 2>&1 \
		|| die "make batocera-rf35h_defconfig"
	# nome e versione: la cartella di un pacchetto e' build/<nome>-<versione>
	make -s -C "${cfg}" show-info 2>/dev/null \
		| python3 -c 'import json,sys; d=json.load(sys.stdin); print("\n".join(sorted("%s %s" % (k, v.get("version") or "") for k,v in d.items() if v.get("type") in ("target","host"))))' \
		> "${W}/packages.txt"
	echo "  $(wc -l < "${W}/packages.txt") pacchetti"
	rebuild
	# shellcheck disable=SC1091
	. "${TREE}/.rf35h-overlay"
	note notice "Albero" "Batocera ${BATOCERA_COMMIT:0:7} + overlay ${OVERLAY} = ${TREE_HEAD:0:7}; $(wc -l < "${W}/packages.txt") pacchetti; container ${digest}"
}

# RF35H_REBUILD: le cartelle di quei pacchetti si tolgono, e buildroot li rifa'
rebuild() {
	local p ver dir
	for p in ${RF35H_REBUILD:-}; do
		ver="$(awk -v p="${p}" '$1 == p {print $2; exit}' "${W}/packages.txt")"
		grep -q "^${p} " "${W}/packages.txt" || die "RF35H_REBUILD: ${p} non e' un pacchetto di questa build"
		dir="${OUT}/build/${p}${ver:+-${ver}}"
		if [ -d "${dir}" ]; then
			rm -rf "${dir}"
			echo "  ${p}: da rifare"
		else
			echo "  ${p}: non ancora costruito"
		fi
	done
	[ -z "${RF35H_REBUILD:-}" ] || note notice "Da rifare" "${RF35H_REBUILD}"
}

# il log completo della build di questa parte
mainlog() { echo "${W}/build-${RF35H_STAGE:-1}.log"; }

# Il log senza \r e codici di colore: col terminale (docker run -t) buildroot
# mette ">>> pacchetto versione passo" tra due sequenze di escape.
plain() { sed -u -e 's/\r$//' -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b(B//g'; }

# pacchetti finiti / totali, e l'ultimo passo fatto (lo stamp piu' recente:
# non serve leggere un log di GB)
progress() {
	paths
	local finished total last
	finished="$(find "${OUT}/build" -mindepth 2 -maxdepth 2 -name .stamp_installed 2>/dev/null | wc -l)"
	total="$(wc -l < "${W}/packages.txt" 2>/dev/null || echo '?')"
	# shellcheck disable=SC2012
	last="$(ls -t "${OUT}"/build/*/.stamp_* 2>/dev/null | head -1 | sed -E 's|.*/build/([^/]+)/\.stamp_(.*)|\1 \2|')"
	echo "pacchetti finiti ${finished} su ${total}${last:+, ultimo passo: ${last}}"
}

# Lo stato del commit (contesto build/parte-N), letto dall'API e mostrato da
# GitHub accanto al commit: l'unico modo di seguire una parte mentre gira
# (log e artifact arrivano solo alla fine). Serve GH_TOKEN con statuses:write;
# un errore qui non ferma niente.
status() {	# stato (pending|success|failure) descrizione
	[ -n "${GITHUB_ACTIONS:-}" ] && [ -n "${GH_TOKEN:-}" ] || return 0
	local desc="$2"
	[ "${#desc}" -le 140 ] || desc="${desc:0:137}..."
	gh api -X POST "repos/${GITHUB_REPOSITORY}/statuses/${GITHUB_SHA}" \
		-f state="$1" -f context="build/parte-${RF35H_STAGE:-1}" -f description="${desc}" \
		-f target_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID:-}" \
		>/dev/null 2>&1 || true
}
short_progress() {	# "123/847 llvm-21.1.0 built, 80 GB, 42 min"
	paths
	local finished total last
	finished="$(find "${OUT}/build" -mindepth 2 -maxdepth 2 -name .stamp_installed 2>/dev/null | wc -l)"
	total="$(wc -l < "${W}/packages.txt" 2>/dev/null || echo '?')"
	# shellcheck disable=SC2012
	last="$(ls -t "${OUT}"/build/*/.stamp_* 2>/dev/null | head -1 | sed -E 's|.*/build/([^/]+)/\.stamp_(.*)|\1 \2|')"
	echo "${finished}/${total} ${last:-?}, $(gb "${W}") GB liberi, $(( ($(date +%s) - ${JOB_START:-$(date +%s)}) / 60 )) min"
}

# Il pacchetto fallito e le righe che servono a capire perche'. Le righe di
# errore si cercano solo nella coda del log, e senza i falsi positivi delle
# build precedenti (-Werror=..., fterrors.h): quelli di gcc, cargo/rustc,
# make, meson, cmake e del sistema. Poi la coda del log senza le righe di
# comando chilometriche. Tutto tagliato: e' il testo di un'annotazione.
failure_report() {
	local log pkg
	log="$(mainlog)"
	[ -f "${log}" ] || { echo "nessun log"; return 0; }
	pkg="$(tail -n 20000 "${log}" | plain | grep -aoE '/build/[^/ ]+/\.stamp_[a-z_]+\] Error' | tail -1 | sed -E 's|/build/([^/]+)/.*|\1|')"
	echo "pacchetto: ${pkg:-sconosciuto}"
	echo "ultimo passo: $(tail -n 20000 "${log}" | plain | grep -a '^>>> ' | tail -1)"
	echo "--- righe di errore"
	tail -n 3000 "${log}" | plain \
		| grep -aE '(^|[[:space:]])(error|ERROR|Error)(\[[A-Z0-9]+\])?:|^error|fatal( error)?:|\*\*\* |Killed|No space left|Illegal instruction|undefined reference|could not compile|failed to run|panicked at' \
		| grep -avE -- '-W(no-)?error|supports arguments' | cut -c1-250 | tail -20
	echo "--- coda del log"
	tail -n 400 "${log}" | plain | awk 'length($0) < 600' | cut -c1-250 | tail -30
}

cmd_build() {
	paths
	: "${JOB_START:?}" "${BUILD_MINUTES:?}" "${RF35H_CONTAINER:?}"
	local deadline now budget rc=0 result try=1 log
	deadline=$(( JOB_START + BUILD_MINUTES * 60 ))
	now="$(date +%s)"
	log="$(mainlog)"
	# Durante la build, sotto i 40 GB liberi, si potano i pacchetti finiti
	# (gli stessi che pack poterebbe alla fine): i loro oggetti non servono
	# piu' a nessuno, e il disco del runner non basta per tenerli tutti.
	(
		while sleep 300; do
			if [ "$(gb "${W}")" -lt 40 ]; then
				"$O/tools/prune-build.sh" "${OUT}" >> "${W}/prune.log" 2>&1 || true
			fi
		done
	) &
	local pruner=$!
	# l'avanzamento ogni 10 minuti nello stato del commit
	(
		while sleep 600; do status pending "$(short_progress)"; done
	) &
	local reporter=$!
	# shellcheck disable=SC2064
	trap "kill ${pruner} ${reporter} 2>/dev/null || true" EXIT
	status pending "build iniziata: $(short_progress)"
	while : ; do
		budget=$(( deadline - $(date +%s) ))
		if [ "${budget}" -lt 1200 ]; then
			if [ "${try}" -gt 1 ]; then break; fi   # resta l'esito del primo
			echo "meno di 20 minuti per la build: passo lo stato alla parte successiva"
			out "result=continue"
			return 0
		fi
		say "Build (tentativo ${try}): $(( budget / 60 )) minuti a disposizione"
		# Nel log delle actions solo l'inizio di ogni pacchetto e gli errori; il
		# log completo va negli artifact.
		set +e
		timeout --signal=TERM --kill-after=60 "${budget}" \
			env RF35H_CONTAINER="${RF35H_CONTAINER}" \
			"$O/tools/build.sh" --no-apply --tree "${TREE}" --work "${WORKD}" --version "${RF35H_VERSION:-}" 2>&1 \
			| tee -a "${log}" | plain \
			| grep --line-buffered -aE '^>>> [^ ]+ [^ ]+ Building|^==> |\*\*\* |Error [0-9]+$|No space left'
		rc=${PIPESTATUS[0]}
		set -e
		# Allo scadere timeout ferma il client docker; il container lo si
		# ferma e lo si toglie da fuori, cosi' il tentativo dopo riusa il nome.
		docker kill "${RF35H_CONTAINER}" >/dev/null 2>&1 || true
		docker rm -f "${RF35H_CONTAINER}" >/dev/null 2>&1 || true
		case "${rc}" in
			0)       result="done" ;;
			124|137) result="continue" ;;
			*)       result="failed" ;;
		esac
		# Un fallimento si riprova una volta: uno scaricamento interrotto non
		# deve buttare ore di build; uno vero si ripete in pochi minuti,
		# perche' il costruito resta (stamp) e si rifa' solo il pacchetto.
		if [ "${result}" = failed ] && [ "${try}" -eq 1 ]; then
			note warning "Tentativo 1 fallito: riprovo" "$(failure_report)"
			try=2
			continue
		fi
		break
	done
	kill "${pruner}" "${reporter}" 2>/dev/null || true
	[ -f "${W}/prune.log" ] && { echo "potature durante la build:"; cat "${W}/prune.log"; }
	case "${result}" in
		done)     status success "immagini fatte: $(short_progress)" ;;
		continue) status success "continua nella parte $(( ${RF35H_STAGE:-1} + 1 )): $(short_progress)" ;;
		*)        status failure "fallita ($(failure_report | sed -n 's/^pacchetto: //p')): $(short_progress)" ;;
	esac
	echo "uscita ${rc}: ${result}"
	out "result=${result}"
	summ "- build: uscita ${rc} (${result}) dopo $(( ($(date +%s) - now) / 60 )) minuti, tentativi ${try}; $(progress)"
	note notice "Build" "uscita ${rc} (${result}) dopo $(( ($(date +%s) - now) / 60 )) minuti, tentativi ${try}; $(progress); disco: $(gb "${W}") GB liberi, output $(du -sh "${WORKD}/output" 2>/dev/null | cut -f1), dl $(du -sh "${WORKD}/dl" 2>/dev/null | cut -f1)"
	if [ "${result}" = failed ]; then
		note error "Build fallita" "$(failure_report)"
		exit "${rc}"
	fi
}

cmd_pack() {
	paths
	local n="${1:?numero della parte}" kind="${2:-}"
	say "Stato della parte ${n}${kind:+ (build fallita)}"
	"$O/tools/prune-build.sh" "${OUT}"
	local t0; t0="$(date +%s)"
	tar -C "${WORKD}" -cf - output ccache container.txt | zstd -q -T0 -3 > "${W}/state-${n}.tar.zst"
	local size; size="$(du -h "${W}/state-${n}.tar.zst" | cut -f1)"
	echo "  ${W}/state-${n}.tar.zst: ${size} in $(( $(date +%s) - t0 )) s"
	note notice "Stato ${n}" "${size} (output $(du -sh "${WORKD}/output" | cut -f1) dopo la potatura, ccache $(du -sh "${WORKD}/ccache" | cut -f1)); $(progress)"
}

cmd_unpack() {
	paths
	local n="${1:?numero della parte}" f
	f="${W}/dl-state/state-${n}.tar.zst"
	[ -f "${f}" ] || die "manca ${f}"
	say "Stato della parte ${n}"
	mkdir -p "${WORKD}"
	zstd -q -dc "${f}" | tar -C "${WORKD}" -xf -
	rm -f "${f}"
	# Il pacchetto che la parte precedente stava costruendo e' stato fermato
	# con un kill: puo' avere patch applicate a meta' o un oggetto troncato
	# che make crede valido. Si rifa' da capo: si toglie ogni cartella di
	# pacchetto (ha .stamp_downloaded o .stamp_rsynced) senza .stamp_installed.
	# Costa poco: quello che aveva gia' compilato e' nella ccache.
	local d
	for d in "${OUT}"/build/*/; do
		[ -d "${d}" ] || continue
		[ -f "${d}.stamp_downloaded" ] || [ -f "${d}.stamp_rsynced" ] || continue
		if [ ! -f "${d}.stamp_installed" ]; then
			echo "  $(basename "${d}"): interrotto, da rifare"
			rm -rf "${d}"
		fi
	done
	echo "  $(progress)"
}

cmd_collect() {
	paths
	local img="${OUT}/images/batocera/images"
	say "Verifica dell'immagine rf35h"
	# Niente "die" qui: dopo ore di build le immagini si caricano comunque
	# come artifact, anche se un controllo fallisce. L'esito va in
	# W/verdict.txt, e "verdict" fa fallire il job dopo il caricamento.
	local problems=()
	"$O/tools/verify-image.sh" "${img}/rf35h" 2>&1 | tee "${W}/verify.log" || true
	tail -1 "${W}/verify.log" | grep -qx Conforme || problems+=("verify-image: $(tail -1 "${W}/verify.log")")
	say "File della release"
	rm -rf "${W}/dist" "${W}/upstream"; mkdir -p "${W}/dist" "${W}/upstream"
	cp "${img}"/rf35h/batocera-rk3326-rf35h-*.img.gz "${W}/dist/" || problems+=("immagine rf35h assente")
	cp "${img}/rf35h/boot.tar.xz" "${img}/rf35h/boot.tar.xz.md5" "${img}/rf35h/batocera.version" "${W}/dist/" \
		|| problems+=("file dell'aggiornamento assenti")
	cp "${W}/verify.log" "${W}/dist/verify-image.txt"
	(cd "${W}/dist" && sha256sum -- *.img.gz boot.tar.xz batocera.version > SHA256SUMS) || true
	# GitHub non accetta in una release file da 2 GiB in su
	local f
	for f in "${W}"/dist/*; do
		if [ "$(stat -c%s "$f")" -ge $((2 * 1024 * 1024 * 1024)) ]; then
			problems+=("$(basename "$f"): $(du -h "$f" | cut -f1), oltre i 2 GiB di una release GitHub")
		fi
	done
	ls -la "${W}/dist"
	cp "${img}"/mainline/batocera-rk3326-mainline-*.img.gz "${img}/mainline/batocera.version" "${W}/upstream/" \
		|| problems+=("immagine mainline assente")
	note notice "Immagini" "rf35h: $(du -ch "${W}"/dist/*.img.gz 2>/dev/null | tail -1 | cut -f1), boot.tar.xz $(du -h "${W}/dist/boot.tar.xz" 2>/dev/null | cut -f1), batocera.version $(cat "${W}/dist/batocera.version" 2>/dev/null); squashfs $(du -h "${img}/../boot_rf35h/boot/batocera" 2>/dev/null | cut -f1) + rufomaculata $(du -h "${img}/../boot_rf35h/boot/rufomaculata" 2>/dev/null | cut -f1); verify-image: $(tail -1 "${W}/verify.log")"
	# vuoto = tutto a posto (printf con un array vuoto scriverebbe una riga vuota)
	: > "${W}/verdict.txt"
	if [ "${#problems[@]}" -gt 0 ]; then
		printf '%s\n' "${problems[@]}" > "${W}/verdict.txt"
		note error "Immagini caricate, ma con problemi" "$(cat "${W}/verdict.txt")"
	fi
}

cmd_verdict() {
	: "${W:?}"
	[ -f "${W}/verdict.txt" ] || die "manca W/verdict.txt: collect non e' arrivato in fondo"
	if [ -s "${W}/verdict.txt" ]; then
		cat "${W}/verdict.txt"
		die "le immagini hanno problemi (vedi sopra)"
	fi
	echo "Immagini a posto"
}

cmd_logs() {
	paths
	local n="${1:?numero della parte}" list=()
	[ -f "$(mainlog)" ] && list+=("$(basename "$(mainlog)")")
	[ -f "${W}/verify.log" ] && list+=(verify.log)
	if [ "${#list[@]}" -eq 0 ]; then echo "nessun log"; return 0; fi
	tar -C "${W}" -cf - "${list[@]}" | zstd -q -T0 -10 > "${W}/log-${n}.tar.zst"
	ls -la "${W}/log-${n}.tar.zst"
}

cmd_ccache_stats() {
	paths
	local cc="${OUT}/host/bin/ccache"
	[ -x "${cc}" ] || { echo "ccache non ancora costruita"; return 0; }
	# la ccache di buildroot e' un programma del container: gira li'
	local s
	# con l'utente della build: ccache -s puo' scrivere nella cache
	s="$(docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -v "${WORKD}:/w" \
		--entrypoint /w/output/rf35h/host/bin/ccache "${IMAGE}" -d /w/ccache -s 2>&1 || true)"
	echo "${s}"
	note notice "ccache" "$(grep -iE 'hits|misses|cache size' <<<"${s}" | sort -u | tr -s ' ' | paste -sd ';' -)"
}

case "${1:-}" in
	disk)         cmd_disk ;;
	prepare)      cmd_prepare ;;
	build)        cmd_build ;;
	pack)         shift; cmd_pack "$@" ;;
	unpack)       shift; cmd_unpack "$@" ;;
	collect)      cmd_collect ;;
	verdict)      cmd_verdict ;;
	logs)         shift; cmd_logs "$@" ;;
	ccache-stats) cmd_ccache_stats ;;
	*) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 2 ;;
esac
