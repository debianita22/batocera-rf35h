# board/loader: the boot loader the RF35H is known to boot with

`known-good.bin` is bytes 32 KiB to 16 MiB of the official AURKNIX-RK3326
20260809 SD card image, unmodified: idbloader (Rockchip's DDR init, rewritten
by AURKNIX to bring the RAM up at 786 MHz instead of 333, plus the
miniloader), `uboot.img` (U-Boot 2025.10) and `trust.img` (BL31), in
Rockchip's legacy layout. It is the same file as in
[lakka-rf35h](https://github.com/debianita22/lakka-rf35h/tree/main/board/loader)
and devaOS, where it boots the RF35H.

sha256 `52850532f1e1ab8bd96d8557533d6cffe72c0ec920b55eb8cdb2eb1b4de71321`,
16,744,448 bytes (`known-good.sha256`).

Where it goes:

- `tools/apply.sh` checks it against `known-good.sha256` and copies it into
  the Batocera tree, `board/batocera/rockchip/rk3326/rf35h/loader/`;
- the `rf35h` image's `create-boot-script.sh` checks the sha256 again (it
  is written there too) and hands it to genimage, which writes it raw at
  32 KiB; the boot partition starts at 16 MiB, right after it;
- `tools/verify-image.sh` compares the image's bytes 32K..16M with it.

Batocera's updates (`boot.tar.xz`) only replace files on the boot partition,
so the loader is written once, with the image, and never again.

That U-Boot runs boot scripts only (`bootcmd=bootmeth order script;
bootflow scan -b`): the image has a `boot.scr` that hands over to
`extlinux/extlinux.conf` with `sysboot`, after moving `kernel_addr_r` to
0x09000000 (the uncompressed kernel would otherwise run over the device tree).

To capture another loader from a card that boots:

    dd if=/dev/sdX of=known-good.bin bs=32768 skip=1 count=511
    sha256sum known-good.bin > known-good.sha256

(and update `LOADER_SHA256` in `fork/0003`, which `tools/apply.sh` checks).

## Licenses

U-Boot is GPL-2.0-or-later; this binary is AURKNIX's build of it, and its
corresponding source is the AURKNIX distribution
(https://github.com/lcdyk0517/distribution_aurknix, U-Boot 2025.10 with its
RK3326 patches). The DDR init, miniloader and BL31 are Rockchip binaries from
rkbin, redistributed under Rockchip's license as every RK3326 distribution
does.
