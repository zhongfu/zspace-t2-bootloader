# U-Boot and the boot-chain package for the ZSpace T2 (RK3568)

Mainline U-Boot for the board, with the T2's own device tree and a small board
configuration, the raw boot-chain images that come out of the build, and the
`t2-bootloader` package with `/usr/sbin/t2-bootloader-install` - the safe
updater for the eMMC loader region.

This repository is a split of the image repository: it owns the U-Boot build
(`dts/`, `configs/`, `patches/`, `fetch.sh`, `build.sh`), the raw boot-chain
images and the updater.  The kernel, the initramfs, the installer and the
rootfs image live elsewhere; the image build consumes the raw files this repo
publishes.

## What the board port adds

* **Control device tree.** `dts/rk3568-t2.dts` is the board tree
  (`compatible = "zspace,t2"`, `rockchip,rk3568`): RK809 regulators, the UART2
  console, eMMC and SD, the front-panel LEDs and the SARADC `adc-keys`.
  `dts/rk3568-t2-u-boot.dtsi` includes `rk3568-u-boot.dtsi` explicitly and
  deletes the LED `default-state` properties.
* **Power-on gate and LEDs.** `CONFIG_PREBOOT` reads the RK809 power-on source
  (register `0xf5`, i2c0 at `0x20`) and the SoC reset cause. It powers the board
  back off on a fresh plug-in power-on; a button, reset, or watchdog start boots
  normally and lights the red LED. Linux later takes over the same `gpio-leds`
  (green on, red off). Env `t2_boot_on_plugin=1` overrides the gate.
* **Environment on the boot FAT.** `CONFIG_ENV_IS_IN_FAT` with
  `CONFIG_ENV_FAT_DEVICE_AND_PART=":3"` keeps `/uboot.env` in partition 3, the
  FAT boot partition, from the eMMC or the SD card.
* **Bootcount A/B fallback.** `CONFIG_BOOTCOUNT_LIMIT` and
  `CONFIG_BOOTCOUNT_ALTBOOTCMD` boot `/Image.old` after three failed boots.
* **Two boot commands.** The plain image boots the eMMC boot tree; holding the
  power button about 0.5 s selects the card. The installer image boots the
  card's installer tree. Both keep the `rockusb` flash workflow over the Type-C
  OTG port.
* **Host patch.** `patches/0001-dtc-pylibfdt-swig4.patch` teaches
  `scripts/dtc/pylibfdt/Makefile` the Python 2 compatibility defines that swig 4
  no longer emits (`PyInt_AsLong`, `PyString_*`).

## Build

You need a Linux x86-64 host, `git`, `python3`, `swig` (4 or newer), `bison`,
`flex`, an aarch64 cross compiler (`gcc-aarch64-linux-gnu`, or `CROSS_COMPILE`
set), and `dpkg-deb` (from `dpkg`) for the package.

```sh
./fetch.sh      # build/uboot (U-Boot v2026.07) + build/rkbin (bin/rk35)
./build.sh      # -> build/out/
./package.sh    # -> build/t2-bootloader_<version>_arm64.deb
```

`fetch.sh` clones U-Boot at tag `v2026.07` and a sparse
`rockchip-linux/rkbin` (only `bin/rk35`).  `build.sh` installs the defconfigs
and device trees, applies the patches, and builds the installer image first,
then the plain image.  `SOURCE_DATE_EPOCH` is pinned to the U-Boot commit's
time.

The rkbin blobs are `bin/rk35/rk3568_bl31_v1.46.elf` (BL31) and
`bin/rk35/rk3568_ddr_1560MHz_v1.26.bin` (TPL). Override them with `BL31` /
`ROCKCHIP_TPL`; override `UBOOT`, `RKBIN`, `OUT`, or `JOBS` to change the trees,
output, or job count.

The installer defconfig is derived from the plain one on every build
(`gen-installer-defconfig.py`); only `CONFIG_BOOTCOMMAND` differs, so the
installer image cannot silently keep an old preboot/gate.

### Version

`package.sh` derives the package version from this repository's `git describe`,
so the package names the U-Boot release it was built from plus a Debian
revision:

| tag | version |
|---|---|
| `v2026.07` | `2026.07-1` |
| `v2026.07-3-g1a2b3c4` | `2026.07+git3.g1a2b3c4-1` |
| `v2026.07-rc5-3-g1a2b3c4` | `2026.07~rc5+git3.g1a2b3c4-1` |

`~` makes a pre-release sort *before* the plain release and `+` makes a
post-release build sort after it, which is what Debian version ordering means.
Tag a release `v2026.07` (or a later U-Boot version) before publishing; a
checkout with no tags falls back to the U-Boot release `fetch.sh` pins.
`DEB_REV` overrides the Debian revision (default `1`).

## Output

Everything `build.sh` writes goes to `build/out/`:

| File | Purpose |
|---|---|
| `u-boot.itb` | U-Boot + BL31 + DT; the eMMC's raw loader, LBA `0x4000` (GPT p1 `uboot`) |
| `idbloader.img` | TPL + SPL; the eMMC's raw loader, LBA `0x40` |
| `u-boot-installer.itb` | the installer image for the card's loader partition |
| `idbloader-installer.img` | the installer's TPL + SPL |
| `u-boot-initial-env`, `u-boot-installer-initial-env` | the compiled default environment as text |

`u-boot.itb` carries the LED strings (`power-led-red`, `power-led-green`) and
the gate/environment logic. `u-boot-initial-env` is the text other tools turn
into `/uboot.env`.

`package.sh` stages all six into `/usr/lib/t2-bootloader/` and
`t2-bootloader-install` into `/usr/sbin/`, then builds the .deb with a
hand-written `packaging/DEBIAN/` control directory and `dpkg-deb --build` (no
debhelper).  The package is architecture `arm64`, because the payload is the
board's firmware.

## The updater

`/usr/sbin/t2-bootloader-install` writes the boot chain on a running system:

```
t2-bootloader-install [--device DEV] [--dry-run] [--yes] [--force]
```

It validates both images (existence, size, sector alignment, the `RKNS`
idbloader magic and the FDT/FIT magic), checks them against the regions they
land in, prints exactly what it will write where (file, size, sha256, byte
offset, LBA), writes the SPL to LBA `0x40` and U-Boot to LBA `0x4000` with
`dd conv=fsync`, and reads both regions back to compare sha256.  It never
touches the U-Boot environment: that is the FAT file `/uboot.env` in partition
3, outside both loader regions.

The gates:

* every real write needs `--yes`; writing to the disk the running system is on
  is only reachable through the same flag, and the plan says so;
* a run with no evident recovery path - no removable card present, so nothing
  an installer could be booted from - is refused unless `--force`;
* `--device` must be a whole disk (or a regular file, which is how it is
  tested); a partition is refused, because the writes are at absolute LBAs;
* `--dry-run` validates and prints the plan and writes nothing.

`--device` defaults to the whole disk carrying the running root, derived from
`findmnt`/`lsblk`.  That is normally the target, so the plan calls out when the
target carries the running root; `--yes` is required for every write either
way.

### Limits

* It updates only the eMMC boot chain.  It does not touch the kernel, the boot
  tree, or the rootfs, and it does not write the SD-card installer images it
  ships - those are inputs to the image build.
* It cannot rescue a board whose SPL is already broken: the writes are to the
  same region, so there is nothing to fall back to.  Only maskrom over USB
  restores that board (the image repository's `docs/tinkering.md`).
* It does not verify the images cryptographically.  The only signature is the
  package signature; a tampered `/usr/lib/t2-bootloader` would pass the magic
  checks.  The checks catch a wrong file, a truncated file, or the wrong
  variant, not a deliberate forgery.
* It does not use the eMMC's hardware boot partitions.  See below.

## Recovery

The RK3568 BootROM always loads the first-stage loader (the SPL) from the eMMC
at LBA `0x40`.  An SD card cannot replace it: a raw `idbloader.img` on the card
never runs.  So the recovery path depends on which stage is broken.

* **U-Boot, kernel, or rootfs broken, SPL intact.**  Boot the installer SD
  card: the card carries U-Boot in its `uboot` partition and a FAT boot tree,
  and the board's U-Boot selects that tree when the power button is held at
  power-on (a mainline U-Boot on the eMMC applies the same gate).  The installer
  rewrites the eMMC.  This is why the updater refuses without an evident card
  unless `--force`.
* **SPL broken.**  Nothing on the board runs.  Enter maskrom (the button on the
  underside) and restore the loader over USB with `rkdeveloptool`.  Maskrom is
  the recovery path of last resort.

## The eMMC boot partitions: an unverified question

The eMMC exposes two hardware boot partitions, `/dev/mmcblk0boot0` and
`mmcblk0boot1`, which the eMMC standard reserves for a boot area independent of
the user data area.  They suggest a way to make the loader itself A/B - write a
new SPL/U-Boot pair into the inactive boot partition, switch the eMMC's boot
partition, and keep the old one to fall back to.

**This is unverified on this board, and this repository does not claim it
works.**  What is known:

* the vendor layout and the RK3568 BootROM behaviour this port relies on put
  the SPL at LBA `0x40` of the *user data* area, and U-Boot at LBA `0x4000`
  (`images/t2-image.py` and the image repository's `docs/tinkering.md`);
* a dump of the vendor eMMC is the only evidence about `boot0`/`boot1`, and the
  image repository's dump tool records whether the partitions are present but
  not what the BootROM does with them.

What is *not* known, and would need a board to test: whether the RK3568 BootROM
can be pointed at `boot0`/`boot1` at all, whether the eMMC's
`BOOT_PARTITION_ENABLE`/partition-switch (EXT_CSD) is respected by this BootROM,
and whether writing the loader into `boot0`/`boot1` changes what runs or is
ignored.  Until that is measured on hardware, the updater writes the user data
area only, and the loader has no A/B fallback.

## Patch verification

`patches/0001-dtc-pylibfdt-swig4.patch` applies cleanly to upstream U-Boot tag
`v2026.07` (commit `ece349ade2973e220f524ce59e59711cc919263f`) with
`git apply --check`, no offset or reject. Re-check with:

```sh
git -C build/uboot checkout -- .          # restore a clean v2026.07 tree
git -C build/uboot apply --check patches/0001-dtc-pylibfdt-swig4.patch
```
