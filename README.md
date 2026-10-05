# Batocera for the XiFan RF35H

Unofficial [Batocera](https://batocera.org) images for the **XiFan RF35H**
(also sold as XF35H): Rockchip RK3326, 640x480 MIPI-DSI panel, RK817 PMIC,
RK915 Wi-Fi, two analog sticks. Not affiliated with or supported by the
Batocera team: report problems here.

> **Status: experimental.** The device support builds and is checked by
> tools, but the first images have not been tested on a console yet.

This repository holds no copy of Batocera. It pins a Batocera commit and adds
two patch series on top of it:

| Series | What | Where it should end up |
|---|---|---|
| `upstream/` | RF35H support: device tree, rumble motor on a GPIO for `rocknix-joypad`, the gamepad mapping, the RF35H in Batocera's `mainline` RK3326 image, `rk915` loaded from its device tree node | a pull request to [batocera.linux](https://github.com/batocera-linux/batocera.linux) |
| `fork/` | what stays here: the `rf35h` target and image (the loader the RF35H is known to boot with), updates from this repository's releases, a leaner package set; plus two build fixes that are not RF35H-specific (cargo-c's Cargo.lock, cabextract's download site), to be proposed to Batocera separately | here |

## The device

| | |
|---|---|
| Panel | 640x480 at 60.000 Hz (the stock firmware's first mode is 58.5 Hz) |
| Controls | D-pad, ABXY, L1/L2/R1/R2, Select, Start, two sticks with clicks, volume keys. No function key: **the hotkey is Select** |
| Rumble | on/off motor on a GPIO |
| Wi-Fi | RK915 (2.4 GHz), driver and firmware from Batocera's `rk915` package |
| LEDs | red: charging; blue: on; the stick LEDs run their own colour cycle |
| RAM | DDR brought up at 786 MHz by the loader (Batocera's own loaders use 333 MHz) |
| Serial console | `ttyS1`, 1500000 baud (`ttyS2` is wired to the stick LED controller) |

## Install and update

1. Download `batocera-rk3326-rf35h-*.img.gz` from the
   [latest release](../../releases/latest) and write it to a microSD card
   (Raspberry Pi Imager, balenaEtcher, or
   `gunzip -c batocera-rk3326-rf35h-*.img.gz | sudo dd of=/dev/sdX bs=4M conv=fsync`).
   This erases the card.
2. Boot the RF35H from the card. Batocera grows the SHARE partition to the
   whole card on the first boot.

Updates come from this repository: EmulationStation, *Updates & downloads*,
*Start update*. An update replaces the boot partition only; ROMs, saves and
settings on SHARE stay. The loader at the start of the card is never
rewritten.

## The two images

Every build makes two images from the same system:

- `batocera-rk3326-rf35h-*.img.gz` (the release): the loader from
  [`board/loader`](board/loader) (AURKNIX-RK3326 20260809, U-Boot 2025.10),
  a `boot.scr` that hands over to `extlinux.conf`, console on ttyS1.
- `batocera-rk3326-mainline-*.img.gz` (build artifact only): Batocera's own
  RK3326 `mainline` image with the `upstream/` series, i.e. the RF35H as
  Batocera would ship it. Rename `extlinux/extlinux.conf.rf35h` to
  `extlinux/extlinux.conf` on its boot partition before the first boot.

## Building

Batocera builds inside its build container (`batoceralinux/batocera.linux-build`
from Docker Hub). You need Docker, a lot of disk (count on 100 GB) and hours:
the first build compiles about 850 packages, LLVM included.

```sh
git clone https://github.com/debianita22/batocera-rf35h.git
./batocera-rf35h/tools/build.sh
```

`tools/build.sh` runs `tools/apply.sh` (Batocera at the pinned commit in
`batocera.linux/`, plus both series and the loader) and then Batocera's
`make rf35h-build`, with the output in `batocera-rf35h-build/` next to the
repository. The images end up in
`batocera-rf35h-build/output/rf35h/images/batocera/images/`, and
`tools/verify-image.sh <that dir>/rf35h` checks the RF35H one.

Buildroot does not rebuild a package when its patches change: after changing
`upstream/` or `fork/`, run `tools/build.sh <package>-dirclean` (for the
device tree: `tools/build.sh linux-rebuild`), then a normal build.

Quick checks without building (a few minutes): `tools/ci-check.sh`. It
applies the series, configures the `rf35h` target, compiles the device tree
and the joypad and Wi-Fi modules against Batocera's kernel, and runs the
tests of the update script, of the image checker, of the CI steps and of the
image step itself: Batocera's post-image script with our image scripts and
Buildroot's genimage, on dummy files, so that a mistake there shows up in
minutes rather than at the end of a day-long build.

## CI and releases

- `check.yml`: `tools/ci-check.sh` on every push and pull request.
- `build.yml`: the build, in up to eight consecutive 6-hour jobs on GitHub's
  free runners (each job hands its state to the next), then the release.
  A `v*` tag (or *Run workflow* with a version) publishes a release; a tag
  with a dash is a pre-release, which consoles do not update to. *Run
  workflow* without a version, or a push to `ci-test/**`, makes a test build
  whose images stay in the run's artifacts. While a part runs, its progress
  (packages done, current step, free disk) is the commit status
  `build/parte-N`, updated every 10 minutes. A failed part saves its state
  for three days: *Run workflow* with `resume_run` (that run's ID), and
  `rebuild` listing the packages whose patches changed, resumes from it.

## Layout

| Path | |
|---|---|
| `batocera.pin` | the Batocera repository and commit |
| `upstream/`, `fork/` | the two series (`git format-patch`), applied with `git am` |
| `board/loader/` | the RF35H loader with its sha256 and provenance |
| `tools/apply.sh`, `tools/build.sh` | prepare the tree, build |
| `tools/verify-image.sh` | what a finished RF35H image must contain |
| `tools/check-dtb.sh` | device tree and modules against Batocera's kernel |
| `tools/test-*.sh` | tests of the update script, of the image checker, of the CI steps and of the image step |
| `tools/ci-*.sh`, `tools/prune-build.sh` | the CI steps |
| `docs/diario.md` | decisions and verification log (Italian) |

## Licenses

The scripts and documentation here are GPL-2.0 (`LICENSE`). The patches
change files of Batocera and of ROCKNIX's `rocknix-joypad`, and are under the
license of the file they change. The loader is AURKNIX's build of U-Boot
(GPL-2.0-or-later) with Rockchip's DDR init, miniloader and BL31 from rkbin;
see [`board/loader/README.md`](board/loader/README.md).
