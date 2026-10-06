# Batocera per la XiFan RF35H - diario

## 4/10/2026: perche' e come

Dopo il port di Lakka (debianita22/lakka-rf35h) la domanda era se si potesse
fare lo stesso con Batocera. La valutazione (nel progetto: `batocera-rf35h.md`)
ha trovato che Batocera RK3326, sul master di oggi, ha gia' quasi tutto quello
che per Lakka si era portato a mano: kernel 7.2.8, il driver di pannello
`generic-dsi` di ROCKNIX, `rocknix-joypad`, un pacchetto `rk915`. Scelta
dell'utente: **A+B**, cioe' il supporto all'RF35H proposto a Batocera e uno
strato nostro per il resto, **con le build su un repository GitHub apposito**.

Da qui la forma del repository: nessuna copia di Batocera, solo

- `batocera.pin`: Batocera al commit `3b66740` (master del 4/10, v44
  "Malachite" in sviluppo; ultima stabile 43.1 del 30/5);
- `upstream/`: la serie per batocera.linux, in inglese, gia' nella forma di
  una pull request;
- `fork/`: quello che resta qui;
- `board/loader/`: il loader known-good (lo stesso di Lakka e devaOS).

`tools/apply.sh` scarica Batocera a quel commit (col sottomodulo buildroot
che quel commit indica), lo riporta pulito e applica le due serie con
`git am`, con committer e date fissi: lo stesso overlay da' sempre lo stesso
HEAD (verificato: due applicazioni, stesso `04131d2`). La build sta fuori
dall'albero, cosi' riportarlo indietro non tocca niente di costruito.

## La serie upstream

### 0001: il device tree

Viene da `z-010` di lakka-rf35h (il DTS XF35H di AURKNIX piu' le correzioni
RF35H provate sulla console), riscritto in un solo file con commenti in
inglese. Per non perdere niente per strada: il DTS di Lakka e' stato
compilato nello stesso albero di Batocera (senza `&dmc`, che li' non esiste),
i due DTB normalizzati con `dtc -I dts -O dts -s` dai sorgenti preprocessati
(riferimenti simbolici, non phandle) e confrontati. Differenze, tutte volute:

- Wi-Fi: il binding del driver di Batocera invece di quello di AveyondFly
  (sotto);
- joypad: identita' nuova e `rumble-gpios` invece di `rumble-gpio`;
- LED: colori e funzioni, rosso col trigger `battery-charging`, blu
  `default-on`;
- tolti: `chosen { systemd.debug_shell }` (residuo AURKNIX), il regolatore
  `vcc-phy` senza utenti, i gruppi pinctrl non usati, le proprieta' di una
  eMMC che resta disabilitata;
- `simple-audio-card,hp-det-gpios` (la forma che usa il resto di Batocera).

Pannello, scale CPU/GPU (600 MHz compresi), regolatori, tasti, batteria
coi valori OEM, audio: identici.

**Wi-Fi.** Batocera ha un suo `rk915` (ImanolBarba/rk915, porting diverso dal
nostro, provato su R36 Ultra con Batocera v44), con lo stesso firmware del
nostro (sha256 identici). Il suo binding: un nodo `rockchip,rk915` con
`power-gpios` e l'interrupt, e niente `mmc-pwrseq` sull'host SDIO, perche' il
driver accende il chip da se' subito prima di caricare il firmware (il boot
ROM del chip aspetta pochi secondi: e' lo stesso problema che su Lakka si era
risolto caricando il modulo presto). Quindi:

- `power-gpios` GPIO0_A2 (lo stesso pin del vecchio `reset-gpios` del
  pwrseq, attivo basso: alto = acceso, come il driver lo pilota);
- interrupt GPIO0_A5 sul fronte di salita: il nostro driver su Lakka
  chiedeva gia' `IRQF_TRIGGER_RISING` su quel pin (host-wake), e funziona;
- `&sdio` senza `non-removable`: per un host non rimovibile `mmc_rescan`
  gira una volta sola, e la scansione che il driver chiede dopo aver acceso
  il chip non avverrebbe. Come sulla R36 Ultra;
- `supports-rk915` per le quirk MMC del loro kernel (3000-3002, le stesse
  della nostra `r-024` piu' il blocco forzato a 512 byte).

**Joypad.** Il `rocknix-joypad` di Batocera e' quello di ROCKNIX, che usa
gpiod e quindi rispetta i flag del device tree; il fork di AveyondFly usato
su Lakka usava l'API legacy e li ignorava. Per avere gli stessi livelli
fisici sul mux:

| canale | AveyondFly (fisico) a, b | ROCKNIX (logico) a, b |
|---|---|---|
| 0 ABS_RY | 0, 0 | 1, 1 |
| 1 ABS_RX | 0, 1 | 1, 0 |
| 2 ABS_Y  | 1, 0 | 0, 1 |
| 3 ABS_X  | 1, 1 | 0, 0 |

il logico e' l'opposto del fisico su entrambe le linee: `amux-a` e `amux-b`
`GPIO_ACTIVE_LOW`. Il DTS RF35H di Lakka li dichiarava gia' cosi' ("come dice
l'OEM"), e anche l'eeclone di Batocera.

**Hotkey.** L'RF35H non ha un tasto funzione (diario di lakka-rf35h: oltre a
croce, ABXY, dorsali, Select, Start e click degli stick ci sono solo power e
reset). Il `BTN_MODE` del device tree e' un fantasma che tiene allineata la
numerazione. In Batocera la mappatura di `retrogame_joypad` mette l'hotkey
proprio su `BTN_MODE`: irraggiungibile. Il pad ha quindi un'identita' sua
(`XiFan RF35H Gamepad`, 0x484B:0x1135, prodotto non usato da nessun altro
dispositivo di Batocera) e una voce in `es_input.cfg` (0003) uguale a quella
di `retrogame_joypad` ma con l'hotkey su Select, come `odroidgo2_v11_joypad`.

**Caricamento di `rk915`.** Il driver accende il chip da se', e la scheda
SDIO a cui si lega compare solo dopo: il modulo si caricava solo dal modalias
SDIO, cioe' solo se il chip era gia' acceso al boot, e RK3326 non ha un
`/etc/modules.conf` (che `S06modprobe` leggerebbe). La patch 0005 aggiunge
`/etc/modprobe.d/rk915.conf` con un alias sul modalias OF del nodo
`rockchip,rk915` (`of:N*T*Crockchip,rk915*`): udev carica il modulo quando
compare quel dispositivo, qualunque sia lo stato della linea di
alimentazione. Le board senza quel nodo non corrispondono. Serve anche alla
R36 Ultra. La linea host-wake (GPIO0_A5) ha il pull-down come sul firmware
originale, nel `pinctrl-0` di `&sdio` (un pinctrl sul nodo `rk915-wifi` non
verrebbe applicato: nessun driver si lega a quel dispositivo).

**Fix DSI `r-025` di Lakka: non c'e'.** Su Lakka c'era, e non si era mai
provato senza. In Batocera manca, e i sette dispositivi RK3326 col driver
`generic-dsi` (tutti con `flags=0xe03`, come l'RF35H) funzionano senza. Prima
prova senza; se lo schermo resta nero, e' il primo indiziato.

### 0002: il motore su GPIO

Il driver di ROCKNIX pilota solo motori PWM; l'RF35H ha il motore su un GPIO
(il fork di AveyondFly lo gestiva: "add xifan device vibrator"). La patch,
nel pacchetto `rocknix-joypad`: senza `pwm-names` il setup prende
`rumble-gpios` (o `rumble-gpio`) e start/stop lo accendono e spengono;
`rumble_enable`, sospensione e ripresa come per il PWM. Compilata contro la
7.2.8 con le patch di Batocera: nessun avviso; applicata al tarball esatto
del pacchetto (d02ed13).

### 0004: l'RF35H nell'immagine `mainline`

Il DTB va sulla partizione di avvio dell'immagine `mainline` di Batocera,
con un `extlinux.conf.rf35h` da rinominare (come per i dispositivi che
`boot.scr` non riconosce), console spostata su ttyS1. Il riconoscimento
automatico aspetta il valore ADC dell'RF35H: l'immagine rf35h lo passa al
kernel (`uboot.hwid_adc=`), si legge da `/proc/cmdline` sulla console.

## Lo strato fork

- **Target `rf35h`** (`configs/batocera-rf35h.board`): la board RK3326 con
  due immagini dallo stesso sistema, la nostra `rf35h` e la `mainline` di
  Batocera (per provare la serie upstream com'e', solo artifact).
- **Immagine `rf35h`**: il loader known-good a 32K (DDR a 786 MHz; quelli di
  Batocera usano il blob a 333 MHz e nel loro kernel non c'e' un DMC per
  PX30, quindi la RAM resterebbe li'), `boot.scr` che passa a
  `extlinux.conf` con `sysboot` (quel U-Boot esegue solo script: verificato
  su Lakka), `kernel_addr_r` 0x09000000 come nel `boot.ini` mainline di
  Batocera, console su ttyS1.
- **Profilo snello**: niente Kodi, MAME attuale (standalone e libretro),
  Moonlight con Qt 6. 847 pacchetti invece di 978. MAME 2003-Plus resta.
- **squashfs zstd** invece di gzip, come per la maggior parte delle board
  ARM di Batocera (il kernel RK3326 ha `SQUASHFS_ZSTD`): `boot.tar.xz` deve
  stare sotto i 2 GiB che GitHub accetta per un file di release. Il sistema
  e' in due squashfs: `boot/batocera` e `boot/rufomaculata`, dove Batocera
  mette `usr/lib/libretro` (tutti i core) e `usr/bin/mame` (`external.mk`;
  l'initrd li monta insieme). `verify-image.sh` li legge tutti e due.
- **Aggiornamenti dalle release**: `batocera-upgrade` di default guarda
  `https://github.com/<repo>/releases/latest/download` (il repo lo mette
  `apply.sh`, in CI quello che costruisce), dove `boot.tar.xz`, la `.md5` e
  `batocera.version` stanno alla radice; con un URL cosi' non aggiunge board
  e tipo al percorso. Visto che l'URL non nomina piu' la board, un
  aggiornamento dalla rete ora controlla la board dentro l'archivio (lo
  faceva gia' quello da file). Qualunque altro `updates.url` funziona come
  prima. Il loader non si riscrive mai: `do_bootloader_update` tocca solo
  file SPI, Qualcomm, Raspberry Pi e Allwinner, e la partizione di avvio
  dell'RF35H non ne ha (`verify-image.sh` lo controlla su `boot.tar.xz`).
- **Versione**: `44-dev-<Batocera>.rf35h-<versione> <data>`; e' cio' che
  EmulationStation confronta con `batocera.version` dell'ultima release.

## La CI

Il CI di Batocera su GitHub fa solo controlli: le loro build girano altrove.
Qui la build gira sui runner gratuiti, come per Lakka, a parti:

- fino a **otto parti** da 6 ore (Lakka ne aveva quattro: qui i pacchetti sono
  847 contro 340, con LLVM e Clang per host e target); quando una finisce le
  immagini, le successive sono saltate;
- tra una parte e l'altra lo stato e' la cartella di buildroot e la ccache,
  senza sorgenti; prima di impacchettarlo `prune-build.sh` toglie gli
  oggetti dei pacchetti finiti (ne restano gli stamp, e make non li rifa').
  Restano interi `linux` (i moduli esterni compilano contro il suo
  albero), `python3` (target-finalize), `alllinuxfirmwares` e
  `wireless-regdb` (li legge `batocera-initramfs`), e i pacchetti a cui
  rimanda un file di `host/` (`.la`, `.pc`, `.cmake`, `*-config`: vedi
  "Seconda build" sotto): cercato nei `.mk` di Batocera e di buildroot,
  nessun altro pacchetto legge la cartella di un altro;
- durante la build, sotto i 40 GB liberi, la stessa potatura ogni 5 minuti;
- il pacchetto che la parte precedente stava costruendo (fermato con un kill:
  patch a meta', oggetti troncati che make crederebbe validi) si rifa' da capo
  alla parte dopo: si toglie ogni cartella senza `.stamp_installed`. Quello
  che aveva gia' compilato e' nella ccache;
- **date fisse**: `apply.sh` mette 1/1/2026 su tutti i file dell'albero. Git
  scrive i file con l'ora del checkout, e buildroot riconfigura un pacchetto
  kconfig quando il file della configurazione e' piu' recente della `.config`
  costruita: `linux` e `batocera-initramfs` (busybox) si sarebbero rifatti a
  ogni parte;
- **lo stesso container in tutte le parti**: la parte 1 scrive il digest di
  `batoceralinux/batocera.linux-build` che ha usato, lo stato lo porta, le
  parti dopo lo riscaricano per digest (gli strumenti per l'host costruiti
  in una parte devono girare nel container della parte dopo, e Batocera
  aggiorna "latest" quando vuole). Se Docker Hub non risponde, il container
  si costruisce dal `docker/Dockerfile` del commit fissato;
- nel log delle actions solo l'inizio di ogni pacchetto e gli errori, dopo
  aver tolto `\r` e i codici di colore (`docker run -t`: buildroot colora le
  righe `>>>`);
- l'immagine rf35h passa da `verify-image.sh` prima della release; ogni file
  deve stare sotto i 2 GiB. Se un controllo fallisce, i file si caricano lo
  stesso come artifact (dopo decine di ore di build servono comunque, per
  provarli o capire cosa non va), e il job fallisce dopo (`verdict`);
- **avanzamento**: ogni 10 minuti la parte aggiorna lo stato del commit
  `build/parte-N` (pacchetti finiti, ultimo passo, disco libero, minuti):
  si vede su GitHub accanto al commit e dall'API, mentre log e annotazioni
  arrivano solo a fine parte;
- **ripresa**: una parte fallita salva il suo stato (3 giorni). *Run workflow*
  con `resume_run` = l'ID di quel run riparte da li' con le patch del commit
  nuovo (solo build di prova, mai una release); `rebuild` elenca i pacchetti
  da rifare da capo, quelli il cui `.mk` o le cui patch sono cambiati
  (buildroot non se ne accorge da solo).

## Prima build: host-cargo-c (5/10/2026)

La prima build vera (run 37252552005) si e' fermata dopo 2 ore, al
pacchetto 217 di 847, su `host-cargo-c`, due tentativi uguali. Il rapporto
d'errore era inutile: cercando "error" in tutto il log prendeva le prove
`-Werror=...` di meson e `fterrors.h` di freetype. Ora guarda solo la coda
del log, con i formati di errore di gcc, cargo, make e meson, piu' le ultime
righe; con una ripresa dallo stato salvato (il pacchetto interrotto e' il
primo che si rifa') l'errore vero e' arrivato in 4 minuti:

    error: rustc 1.95.0 is not supported by the following packages:
      cargo-credential-libsecret@0.5.10 requires rustc 1.97
      cargo-util@0.2.32 requires rustc 1.97
      kstring@2.0.5 requires rustc 1.96.0

Non c'entra l'RF35H. cargo-c (v0.10.19, dicembre 2025) non ha `Cargo.lock`
nel repository; lo `cargo-post-process` di Batocera allora ne genera uno al
momento dello scaricamento, con le versioni piu' recenti delle dipendenze, e
quelle di oggi vogliono un rustc piu' nuovo dell'1.95 di questo buildroot. Chi
ha lo scaricamento gia' in cache non se ne accorge. Il crate pubblicato su
crates.io porta il `Cargo.lock` del suo rilascio (cargo-util 0.2.25, kstring
2.0.2, cargo-credential-libsecret 0.5.3): `fork/0005` scarica quello (URL
verificato, `post_process_unpack` usa `tar -xzf`, il `.crate` e' un tar
gzip) con un comando di estrazione proprio. Da proporre a Batocera a parte.
Gli altri pacchetti Rust della build hanno tutti il loro `Cargo.lock`
(dmd-play-rust, evsieve, libdovi, libretro-holani, logi-wheel; librsvg e' un
tarball di rilascio GNOME).

## Seconda build: nfs-utils e i .la di libtool (5/10/2026)

La ripresa (run 37280076312) ha passato cargo-c e LLVM per l'host e si e'
fermata dopo 4 ore al pacchetto 384 di 847, `nfs-utils`:

    libtool: error: cannot find the library
      '/rf35h/build/util-linux-2.41.4/libblkid.la'

Questa volta e' colpa della CI. `libmount.la` nel sysroot ha in
`dependency_libs` il percorso della cartella di build di util-linux (libtool
lo scrive cosi' per le librerie dello stesso albero); buildroot sistema i
percorsi `/usr` dei `.la`, non questi, e in una build normale nessuno se ne
accorge perche' la cartella c'e' ancora. La potatura tra una parte e l'altra
l'aveva tolta, e nfs-utils (che linka libmount) e' il primo che l'ha cercata.

`prune-build.sh` ora legge i `.la`, `.pc`, `.cmake`, `.prl` e `*-config` di
`host/` (sysroot compreso), prende i nomi dopo `/build/` e lascia interi
quei pacchetti (`-r` li elenca). `unpack` fa lo stesso controllo sullo stato
che riceve: un pacchetto richiesto ma gia' potato (lo stato viene da una
potatura che non lo sapeva) viene tolto e si rifa', cosi' la ripresa da
37280076312 si cura da sola, senza indovinare `rebuild`. `test-ci-build.sh`
21/21, coi tre casi nuovi (util-linux intero, un `.pc` innocuo non lo
tiene, stato vecchio curato da unpack); con la potatura di prima falliscono.

## Terza build: cabextract.org.uk irraggiungibile (5/10/2026)

La ripresa (run 37318724030) e' andata da 360 a 555 pacchetti in tre ore e si
e' fermata su `host-cabextract`, allo scaricamento: `www.cabextract.org.uk`
non rispondeva dal runner (timeout su tutti gli indirizzi) e il mirror di
buildroot non ha quel file (cabextract e' un pacchetto di Batocera, non di
buildroot). Due tentativi uguali. Non c'entrano ne' l'RF35H ne' la CI: un
sito solo, senza mirror, per un pacchetto che serve ai driver dei pad Xbox
(xone, xow, xpadneo, hid-nx, xpad-noone lo usano per i firmware).

`fork/0006`: gli stessi sorgenti sono la cartella `cabextract/` del
repository `kyz/libmspack` su GitHub, tag `v1.11` (i `mspack/*` sono link a
`../libmspack`, quindi archivio intero e `CABEXTRACT_SUBDIR`); l'albero git
non ha `configure`, quindi `AUTORECONF = YES` con `host-gettext` per
`AM_ICONV`. Provato qui: `autoreconf -i`, `configure
--with-external-libmspack`, `make` -> `cabextract version 1.11` linkato a
libmspack. Prima versione sbagliata: `host-libmspack` non esiste (il
pacchetto libmspack di buildroot non ha la variante host, e nella build c'e'
solo `host-cabextract`; il `.mk` di Batocera per l'host trovava libmspack
nel container, se lo trovava), e make si e' fermato subito senza regola.
Ora il tool per l'host si compila coi sorgenti libmspack dell'archivio
(`--without-external-libmspack`), provato anche questo. Seconda versione
sbagliata: Batocera ha `001-fixfnmatch.patch`, che tocca `config.h.in`;
nell'albero git quel file non c'e' (lo genera autoreconf) e la patch non
si applica. Il tentativo 2 della CI ha mostrato solo "duplicate filename"
(la lista delle patch applicate restava dal tentativo 1): l'errore vero era
nel primo. La patch serviva al cross-compile, dove `AC_REPLACE_FNMATCH` non
puo' eseguire il suo test e sostituisce fnmatch con il suo: stesso effetto
con `CABEXTRACT_CONF_ENV = ac_cv_func_fnmatch_works=yes`, e la patch va
via. Anche questo da proporre a Batocera.

## Quarta build: include-fixed di gcc (6/10/2026)

Con cabextract a posto la ripresa (run 37380547211) e' andata da 555 a 650
in un'ora e si e' fermata su `retroarch`:

    host/lib/gcc/aarch64-buildroot-linux-gnu/14.3.0/include-fixed/rga/RgaApi.h:42:10:
    fatal error: drmrga.h: No such file or directory

Un header di `rockchip-rga` dentro `include-fixed` di gcc, da solo, senza il
`drmrga.h` che sta accanto nel sysroot. Ce l'ha messo fixincludes, che gira
quando gcc si compila e copia in `include-fixed` le sue versioni "corrette"
degli header che trova nel sysroot: su un sysroot vuoto (la toolchain si fa
per prima) non trova niente, ma qui gcc era stato **rifatto** a build
avanzata, dalla cura di `unpack` del giorno prima. `libstdc++.la` nomina la
cartella di build di gcc (`-L/rf35h/build/host-gcc-final-14.3.0/...`), la
scansione dei `.la` l'ha presa per un rimando e, siccome gcc era potato,
l'ha fatto rifare. Effetto collaterale di una mia cura, non di Batocera.

Due correzioni: la scansione conta solo i file nominati (`.la`, `.a`, `.so`
dentro `/build/<pacchetto>/`), non un `-L` che e' solo una cartella di
ricerca in piu' e puo' mancare; e la toolchain (`host-gcc-*`,
`host-binutils-*`, `glibc-*`, `linux-headers-*`) non si rifa' comunque. Per
lo stato gia' salvato, `unpack` ripulisce `include-fixed`: via cio' che
esiste anche in `sysroot/usr/include`, tranne `limits.h`, `syslimits.h` e
`README` che sono di gcc. `test-ci-build.sh` 23/23 coi due casi nuovi.

## Revisione indipendente (5/10/2026)

Un agente che non aveva visto il lavoro ha controllato serie, script e
workflow sui sorgenti. Due difetti veri, entrambi corretti:

- **La potatura toglieva `python3`.** Con `BR2_PACKAGE_PYTHON3_PY_PYC=y`
  (in `batocera-board.common`) target-finalize compila i `.pyc` con
  `$(PYTHON3_DIR)/Lib/compileall.py`, e i pacchetti python con estensioni C
  hanno `_PYTHON_PROJECT_BASE=$(PYTHON3_DIR)`: senza quella cartella si
  compilerebbero con gli header dell'host, senza errori. python3 e' il
  pacchetto 77 di 847: la fine della parte 1 l'avrebbe potato, e la build
  sarebbe fallita in target-finalize dopo una trentina d'ore. Il mio scan
  dei `.mk` escludeva i riferimenti di un pacchetto alla propria cartella;
  rifatto su tutti gli hook di target-finalize e rootfs: solo `python3` e
  `linux`. La regola ora vuole il nome esatto (`linux-7.2.8`, non
  `linux-headers-7.2.8` ne' `python3-configobj-*`). La build in corso (196
  pacchetti su 847 in 83 minuti) e' stata fermata; la ccache resta.
- **"Aggiorna" in EmulationStation non usava il nostro `batocera-upgrade`.**
  ES (`ApiSystem::updateSystem`) per un aggiornamento dalla rete scarica lo
  script dal master di batocera.linux su GitHub e lancia quello; il
  controllo invece usa lo script installato. Risultato: aggiornamento
  proposto, installazione fallita su `updates.batocera.org/rf35h/...`.
  `fork/0004` toglie lo scaricamento (verificato che la serie di patch di ES
  applica nell'ordine di buildroot); `verify-image.sh` controlla che il
  binario non contenga piu' quell'URL. `test-upgrade.sh` chiamava lo script
  direttamente, per questo non se n'era accorto.

E due minori:

- **Lunghezza della versione.** ES scarta una `batocera.version` di 49
  caratteri o piu'. Il formato `44-dev-3b66740.rf35h-<V> data` lasciava 10
  caratteri a V; ora e' `44-dev-rf35h-<V> data` (il commit di Batocera lo
  dice `batocera.pin`), V fino a 18, controllato da `build.yml` e
  `build.sh`, e dai due lati del limite in `test-upgrade.sh`. Quando
  Batocera uscira' dalla `-dev`, `batocera-system.mk` non mettera' piu'
  `BATOCERA_GIT_COMMIT` nella versione: `verify-image.sh` se ne accorgerebbe
  (`-rf35h-`), e servira' una patch in `fork/`.
- Una build di prova ripresa da un run fallito tiene la versione del primo
  run (`batocera-system` non si ricostruisce): solo per le prove, le
  release partono da zero.

Segnalato ma non vero: "il loader AURKNIX non imposta `hwid_adc`". Nel
binario c'e', accanto a "Read SARADC failed" e "board_name": e' lo stesso
codice della patch `0002-odroid-go2-hwid-adc` di Batocera.

Rischio che resta, non verificabile senza la console: il riconoscimento
della scheda SDIO del Wi-Fi. Senza `non-removable`, `cd-gpios` e
`broken-cd`, dw_mmc legge il registro CDETECT; se dice "assente",
`mmc_rescan` non enumera il chip neanche dopo che il driver l'ha acceso.
`non-removable` non si puo' usare (con quello `mmc_rescan` gira una volta
sola, prima che il driver accenda il chip). La R36 Ultra di Batocera ha lo
stesso nodo e il driver dice di funzionare. Se sull'RF35H il Wi-Fi non
compare: `broken-cd` in `&sdio` (polling ogni secondo) e' la prima prova.

## L'ultimo passo, provato subito (5/10/2026)

In una build vera `post-image-script.sh` gira una volta sola, alla fine
dell'ultima parte: un errore nel nostro `create-boot-script.sh`, nel nostro
`genimage.cfg` o nell'`extlinux.conf.rf35h` della mainline si sarebbe visto
dopo un giorno e piu' di build. `tools/test-image-step.sh` lo fa girare in
tre minuti, come lo chiama buildroot (`$(EXTRA_ENV) script $(BINARIES_DIR)`,
lo script ha `#!/bin/bash -e`), col `.config` vero del target rf35h, su una
cartella delle immagini finta: kernel, initrd, U-Boot mainline e DTB delle
altre console finti; i due squashfs di `test-verify-image.sh`
(`--make-system`); il nostro DTB e il loader known-good veri. genimage e'
quello del buildroot fissato (19, sorgente da GitHub controllato con
`genimage.hash`); mkimage, mtools, dosfstools ed e2fsprogs quelli del
sistema. Poi `ci-build.sh collect` e `verdict` sulla cartella che ne esce.

Risultato: le due immagini si fanno, coi nomi che si aspetta la CI
(`batocera-rk3326-rf35h-44-<data>.img.gz`: il target di Batocera resta
RK3326, la sotto-immagine e' rf35h), `verify-image.sh` dice "Conforme"
sull'immagine fatta dagli script veri, U-Boot mainline sta a 32K, 8M e 12M,
nella FAT della mainline ci sono il nostro DTB e `extlinux.conf.rf35h` con
ttyS1, `collect` mette i file giusti in dist e upstream, `verdict` passa.
Controprove: loader a 16K invece che a 32K -> `verify-image` lo vede; loader
a 64K -> genimage rifiuta (si sovrappone alla FAT a 16M); console della
RF35H non cambiata nella mainline -> il controllo di extlinux.conf.rf35h
fallisce.

Stato dei test (tutti in `ci-check.sh`, quindi a ogni push e prima di ogni
build): `test-upgrade` 12, `test-verify-image` 26 (l'immagine giusta e 25
mutazioni), `test-ci-build` 23, `test-image-step` 9.

Cercati anche, nei .mk degli 847 pacchetti, scaricamenti fuori dalla fase di
download (che, come `cargo-c`, prenderebbero l'ultima versione di qualcosa):
`cgenius` clona cosmos ma lo fissa a un commit, `mangohud` scarica i wrap di
meson (versioni e hash nei file .wrap), `xone` scarica firmware Microsoft
con hash e senza fallire se manca. Nessuna versione su un ramo (`master`,
`main`...): quelli senza versione sono pacchetti locali o virtuali. Nessun
altro rischio di quel tipo.

## Verificato (host x86_64, 4/10/2026)

- `tools/ci-check.sh` intero, 131 s: script (shellcheck, actionlint),
  loader, serie applicate, configurazione del target rf35h (847 pacchetti,
  85 core libretro; ci sono rk915, rocknix-joypad, U-Boot mainline; non ci
  sono Kodi, MAME attuale, Moonlight, Qt 6, U-Boot hardkernel).
- DTB contro Linux 7.2.8 con le 34 patch RK3326 di Batocera: nessun avviso
  dal nostro file con W=1. `rocknix-joypad` (due moduli, con la patch del
  motore) e `rk915` compilano col gcc 13 aarch64. Controprova: senza la
  patch del motore `check-dtb.sh` fallisce.
- `test-upgrade.sh` 10/10 (controllo, aggiornamento, board sbagliata, md5
  sbagliata, `updates.url` di Batocera con stable e butterfly). Controprova:
  senza la riga `validate_arch` il caso "board sbagliata" fallisce.
- `test-verify-image.sh`: immagine giusta conforme, 23 mutazioni (loader,
  partizioni, console, FDT, boot.scr, board, DTB, moduli, firmware, alias di
  rk915, es_input, URL, versione, core, profilo snello nei due squashfs,
  md5, loader SPI) tutte rilevate.
- `test-ci-build.sh` 18/18 (poi 21): stato tra una parte e l'altra (pacchetti finiti
  potati con gli stamp, `linux` intero, i pacchetti interrotti tolti, ccache
  e digest del container portati), `rebuild`, `collect`/`verdict` con
  un'immagine giusta e una rotta. Ha trovato un errore vero: con nessun
  problema `printf` su un array vuoto scriveva una riga vuota, e `verdict`
  avrebbe bocciato un'immagine buona.
- Il comando docker che `make rf35h-build` esegue (dry run del Makefile di
  Batocera): due `docker run`, defconfig poi build, con `--name rf35h-build`
  e le cartelle fuori dall'albero.

Non verificabile qui: la build vera (Docker Hub non e' raggiungibile da
questa macchina; la prima build sara' quella in CI), e l'hardware.

## Da verificare sulla console

1. Immagine `rf35h`: avvio, immagine sul pannello (senza `r-025`), 60 Hz.
2. Pad in EmulationStation, hotkey Select (Select+Start esce dal gioco),
   direzione degli stick, vibrazione.
3. Wi-Fi: modulo, scansione, connessione, MAC stabile tra un avvio e
   l'altro.
4. Audio da altoparlante e cuffie, tasti del volume.
5. Batteria, LED rosso in carica, tasto power, sospensione.
6. `cat /proc/cmdline`: il valore di `uboot.hwid_adc` (per il riconoscimento
   automatico nell'immagine mainline).
7. Immagine `mainline` (artifact): si avvia col U-Boot di Batocera?
8. Dopo la prima release: un aggiornamento da EmulationStation.

## Da fare

- I core della collezione che Batocera RK3326 non ha: **mame2010** (romset
  0.139), gpsp (c'e' ma solo per BCM2835), e gli altri del set di Lakka.
- I giochi di lakka-rf35h (IKEMEN, GTA SA, re3, OpenXeenNG, Deva) come sistemi
  o port di Batocera.
- I LED degli stick (protocollo della MCU su ttyS2, `rf35h-led` di Lakka).
- Dopo la prova sulla console: fork di batocera.linux e pull request con
  `upstream/`.
