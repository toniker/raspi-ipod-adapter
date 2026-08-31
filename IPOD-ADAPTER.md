# Raspberry Pi iPod Adapter — Task Tracker

Turn a Raspberry Pi Zero 2 W into a car appliance that pairs with a phone over
Bluetooth, receives audio as an A2DP sink, and re-presents it to the car head
unit as an iPod over USB.

**Target car:** 2005 Volvo S40 (USB iPod input)
**Target board:** Raspberry Pi Zero 2 W (BCM2710, Cortex-A53)
**Build system:** Buildroot 2025.08 (vendored in this repo)

```
phone --A2DP/AVRCP--> BlueZ --> bluealsa --> alsaloop --> ALSA "iPodUSB" --USB--> car
                        |                                      ^
                        | AVRCP metadata (D-Bus)               | iAP over /dev/iap0
                        +-------------> ipod client (Go) ------+
                        ^                    |
                        +--- media keys -----+
```

This is the target architecture. The current image has the Bluetooth and
bluealsa pieces; `ipod-gadget`, the Go iAP client, and the `alsaloop` routing
remain Phase 2–4 work.

---

## Architecture decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | **Buildroot**, not a hand-rolled distro or Yocto | Buildroot's design centre is exactly this: no on-target package manager, whole-image rebuilds, tiny init. Yocto's OTA/maintenance strengths aren't needed for a personal appliance. |
| D2 | **Everything in RAM via initramfs** (`BR2_TARGET_ROOTFS_CPIO` + `BR2_TARGET_ROOTFS_INITRAMFS`, embedded in the kernel image) | Immutability is structural rather than enforced. No rootfs mount, no fsck, no journal replay. The car cutting USB power becomes a non-event — the current 120 MB ext4 rootfs would eventually corrupt under repeated unclean power loss. |
| D3 | **One small rw partition mounted at `/var/lib/bluetooth`** | BlueZ persists pairing keys there. Without it the appliance re-pairs on every ignition. This is the *only* mutable state in the system. |
| D4 | Everything else (`/var/log`, `/tmp`, `/run`) on **tmpfs**, discarded on power loss | Nothing else needs to survive a reboot. |
| D5 | **bluez-alsa + alsaloop**, not PulseAudio | Small daemon exposing BT audio as ALSA PCMs; handles AVRCP for metadata; doesn't drag a session-bus userspace into an initramfs. `alsaloop` gives rate adaptation for the phone-clock vs USB-isochronous-clock drift. |
| D6 | **BusyBox init**, not systemd | Boot time; nothing here needs systemd's dependency graph. |
| D7 | **Kernel `hci_uart`/`btbcm` firmware load**, explicitly activated at boot, not `brcm_patchram_plus` | The manual patchram path is legacy and fights the DT-bound driver. `S35hci-uart` runs `modprobe hci_uart` before `bluetoothd`, binding the DT-described BCM43438 and uploading its `.hcd` firmware. |
| D8 | Pi **initiates** reconnect to the last-known phone on boot | Waiting for the phone to notice us is the dominant term in ignition→audio latency (2–10 s) and is otherwise out of our control. |
| D9 | **Bluetooth stays on the PL011 UART** — no `dtoverlay=miniuart-bt` | The old config moved BT to the mini-UART, whose baud derives from the ARM core clock, forcing `core_freq` to be pinned or HCI traffic corrupts. That is a known cause of the exact "HCI interface not found" failure the old init script kept hitting. BT is the critical path; a headless appliance needs no production serial console, so BT gets the better UART. `enable_uart=1` (console on ttyS0) is kept for bring-up only and should be dropped in Phase 6. |
| D10 | **Buildroot-built internal toolchain**, not Bootlin's prebuilt | `toolchain-external-bootlin/Config.in` is gated on `BR2_HOSTARCH = "x86_64"`; the build host is an Apple Silicon Mac, so the build container's VM is aarch64 and Bootlin can never be selected — kconfig would silently drop it. Building our own keeps the container native (the alternative, an emulated amd64 image, puts every compiler invocation under Rosetta) and makes the build host-arch independent. Costs ~20–40 min on the first build only. |
| D12 | **Bluetooth core and HCI UART support enabled — requires `CONFIG_RFKILL=y`** | The kernel declares `config BT ... depends on RFKILL \|\| !RFKILL`, and the RPi `bcm2709` defconfig ships `CONFIG_RFKILL=m`. A `=y` symbol cannot depend on an `=m` one, so kconfig silently clamps `CONFIG_BT=y` back to `m`. The final configuration enables RFKILL, the Bluetooth core, serdev, and the BCM HCI UART support. On the real Pi, the controller did not appear until `modprobe hci_uart` was run; with no device manager to autoload it, `S35hci-uart` now explicitly activates the driver before BlueZ. |
| D11 | **`alsa-plugins` selected, for `libsamplerate`** | `bluez-alsa` only selects libsamplerate `if BR2_PACKAGE_ALSA_PLUGINS`, and its own Config.in says that plugin "is needed for proper sample rate conversion with Bluetooth devices". Phase 4 has to reconcile two clock domains — have the good resampler in the image before that debugging starts. |

### Boot budget (ignition → audio)

Optimise the right term. Rootfs choice is worth ~0.5 s; reconnect strategy is worth ~5 s.

| Stage | Rough cost | Tunable? |
|---|---|---|
| Pi firmware (`bootcode` → `start.elf` → kernel) | 1–2 s | Barely (`boot_delay=0`, `disable_splash=1`, trim firmware) |
| Kernel decompress + init | 1–3 s | **Yes** — strip config hard, `quiet` |
| BT firmware upload + `bluetoothd` | 1–2 s | Some (D7) |
| **Phone reconnect** | **2–10 s** | **Dominant** — attack via D8 |
| Car USB enumeration + iAP handshake | 1–3 s | Not really |

---

## Phase 0 — De-risk the gadget side ✅ DONE

Proven on a throwaway Raspbian install before investing in Buildroot.

- [x] ipod-gadget kernel modules build and load
- [x] `/dev/iap0` appears, `ipod` client runs
- [x] **Audio streams successfully to the 2005 Volvo S40**
- [x] No MFi authentication challenge from the head unit

> The 2005 head unit predates the era where cars challenge for MFi auth — this is
> why we sailed past the wall that [issue #24 (Volvo V70 2015)](https://github.com/oandrew/ipod-gadget/issues/24)
> appears to have hit. **The hardest unknown is retired.**

---

## Phase 1 — Fix the Buildroot foundation

The repo currently builds for the **wrong board** with an audio stack that was
never compiled in. Start from `configs/raspberrypizero2w_defconfig` rather than
patching `raspberrypi0w_defconfig`.

- [x] New `configs/ipod_adapter_defconfig` targeting Zero 2 W (Cortex-A53, `bcm2709`, DTB `bcm2710-rpi-zero-2-w`)
- [x] Switch rootfs to CPIO/initramfs embedded in the kernel (D2); drop `BR2_TARGET_ROOTFS_EXT2`
- [x] Wire up `linux-bt.fragment` via `BR2_LINUX_KERNEL_CONFIG_FRAGMENT_FILES` — it is currently an orphan file that was never applied
- [x] Add USB gadget kernel fragment: `USB_GADGET`, `USB_LIBCOMPOSITE`, `USB_CONFIGFS`, `USB_F_MASS_STORAGE`, `USB_DWC2` (peripheral/OTG)
- [x] Add `dtoverlay=dwc2` to the board `config.txt`
- [x] Select `BR2_PACKAGE_BLUEZ_ALSA` + `alsa-utils` (for `alsaloop`); confirm no PulseAudio anywhere
- [x] Fix the BT UART: `dtoverlay=miniuart-bt` puts BT on `/dev/ttyS0`, but `S98bluetootha2dp` hardcodes `/dev/ttyAMA0`. Prefer removing patchram entirely (D7).
- [x] Fix `main.conf`: class `0x200420` (the Audio service-class bit `0x200000` was dropped in `1bafdeed`); remove invented keys `PinCode`, `[General] AutoConnect`, `[Policy] AutoConnect`; use `[Policy] AutoEnable=true`; drop irrelevant `[LE]`/`[GATT]` sections
- [x] Replace `simple-pin-agent` — it only re-registers an agent every 30 s and implements no D-Bus methods. Resurrect the Python agent from `ca3d0f03`, or use `bt-agent`.
- [x] Partition layout: boot (FAT) + tiny rw data partition; update `genimage.cfg.in`

All custom board files now live in `board/ipod-adapter/` (not `board/raspberrypi/`,
which is symlink-shared by every other Pi board config). `configs/raspberrypi0w_defconfig`
and the custom files under `board/raspberrypi/` (`main.conf`, `simple-pin-agent`,
`S98bluetootha2dp`) are superseded and now dead weight, kept only for diffing.

**Gate:** image boots on Zero 2 W, phone pairs, A2DP sink appears.

- [x] Image **builds** cleanly and contains the intended userspace (see Phase 1b)
- [x] **Boots on real hardware** — Zero 2 W serial console verified; the BCM43430A1 firmware loaded successfully after `modprobe hci_uart`
- [ ] **Phone pairs** and the A2DP sink appears

The remaining phone/A2DP gate is hardware-only and cannot be checked from the
build host. The first flashed image required manually running `modprobe
hci_uart`; the rebuilt image includes `S35hci-uart` to perform that step at
boot. Attach a serial console on **ttyS0** (115200 — note `enable_uart=1` is
present for exactly this, and should be removed in Phase 6) when validating the
new image.

## Phase 1b — Containerised build environment ✅ DONE

See `build/README.md`. `./build/br setup && ./build/br defconfig && ./build/br make`.

- [x] `build/Containerfile` (native aarch64 Debian bookworm, Buildroot's full mandatory host-dep list, non-root `br` user matching host uid/gid)
- [x] `build/br` wrapper around Apple's `container` runtime (CLI 1.2.2) — output and download cache in volumes, not on the slow virtiofs bind mount; 8 CPU / 8 GB per run, overridable via `BR_CPUS` / `BR_MEMORY`
- [x] **Verified** the defconfig applies and all intended symbols survive kconfig resolution, including `BR2_PACKAGE_LIBSAMPLERATE` (pulled in via D11) and `BR2_TARGET_ROOTFS_CPIO` (auto-selected by initramfs). Confirmed absent: PulseAudio, python3, brcm_patchram_plus, ext2/4.
- [x] **Full build succeeds** (exit 0). Artifacts in `images/`: `sdcard.img` 72M, `zImage` 34M (kernel + embedded initramfs; raw `rootfs.cpio` is 38M), `boot.vfat` 64M, `data.ext4` 8M, `bcm2710-rpi-zero-2-w.dtb`.

**Fixed during the first build:** `BR2_GLOBAL_PATCH_DIR` needs
`patches/linux-headers/linux-headers.hash`, which upstream ships as a **symlink**
to `../linux/linux.hash`. Copying `board/raspberrypi/patches/` into the new board
dir silently dropped it (`find -type f` doesn't list it, so the copy looks
complete), and with `BR2_DOWNLOAD_FORCE_CHECK_HASHES=y` a missing hash is fatal:
`ERROR: No hash found for linux-ac69f097....tar.gz`. Recreated as a symlink so the
two hashes cannot drift.

### Verified in the built image, not just the config

- Init order is correct: `S30dbus` → `S32bt-data` → `S35hci-uart` → `S40bluetoothd` → `S45bt-audio` (the data-partition mount really does precede bluetoothd). `S35hci-uart` was added after hardware bring-up showed no service was autoloading `hci_uart`; manual `modprobe hci_uart` immediately created `hci0` and loaded `BCM43430A1.raspberrypi,model-zero-2-w.hcd`.
- Present: `bluealsa`, `bt-agent`, `alsaloop`, `bluetoothctl`, `libsamplerate.so.0.2.2`, `etc/bluetooth/main.conf`
- `bin/usleep` present — `S45bt-audio`'s hci0 wait loop depends on it, because Buildroot's busybox config omits `FEATURE_FLOAT_SLEEP` and `sleep 0.5` would fail
- BT firmware includes the board-specific aliases `BCM43430A1.raspberrypi,model-zero-2-w.hcd` **and** `BCM43430B0.raspberrypi,model-zero-2-w.hcd` — which of the two the driver loads depends on the chip revision on the actual board
- Absent, as intended: PulseAudio, python3
- Boot partition usage ≈ 38M of 64M (`zImage` 34M + `start.elf` 3M + firmware/overlays), so the 64M guess holds with headroom
- **Kernel now has `CONFIG_BT=y`, `CONFIG_BT_HCIUART=y`, `CONFIG_BT_HCIUART_SERDEV=y`, `CONFIG_BT_BCM=y`, `CONFIG_RFKILL=y`** — verified in the rebuilt `.config`. The real target still requires explicit `modprobe hci_uart` activation, now performed by `S35hci-uart`; see D12.
- `CONFIG_BT_HCIVHCI=y` added so the userspace stack can be exercised under QEMU without a real BCM43438. Inert on target — instantiates nothing unless something opens `/dev/vhci`.

## Phase 2 — Package the gadget kernel modules

- [x] `package/ipod-gadget/` using Buildroot's `kernel-module` infra, built against the pinned RPi kernel tree
- [x] Pin to a specific upstream commit + hash (`BR2_DOWNLOAD_FORCE_CHECK_HASHES=y` is already on) — pinned to `ece6b7b0` (oandrew/ipod-gadget master, 2025-08-15), the commit that *is* the "hid_descriptor.rpt_desc on >= 6.12.34" fix. sha256 in `ipod-gadget.hash`, locally computed.
- [x] Verify against our kernel version — **our kernel is 6.12.41** (raspberrypi/linux@`ac69f097`). That is **≥ 6.12.34**, so the upstream "Use hid_descriptor.rpt_desc on >= 6.12.34" commit (Aug 2025) **is required** — pin to current master, not an older commit.
- [x] Init script: modprobe order is `g_ipod_audio` → `g_ipod_hid` → `g_ipod_gadget` — `board/ipod-adapter/rootfs_overlay/etc/init.d/S50ipod-gadget`. Order is load-bearing: the three modules have no inter-module symbol dependency (g_ipod_gadget resolves the audio/hid functions by *name* at runtime), and there is no module autoloader, so `modprobe g_ipod_gadget` alone would not pull the other two.
- [x] Carry over any module params that proved necessary in Phase 0 (`only_ipod`, `swap_configs`, `product_id`) — Phase 0 streamed audio with **stock params**, so the default is empty. Knobs exposed via `/etc/default/ipod-gadget` (`GADGET_ARGS=`), passed only to `g_ipod_gadget`.

**Build-verified** (`./build/br make`, exit 0):

- All three modules compile against 6.12.41 and install to the initramfs at
  `/lib/modules/6.12.41-v7/updates/{g_ipod_audio,g_ipod_hid,g_ipod_gadget}.ko.xz`.
  `vermagic` matches the kernel exactly. zImage 34M → 35M.
- `IPOD_GADGET_LINUX_CONFIG_FIXUPS` resolved as expected: `CONFIG_SND` /
  `CONFIG_SND_PCM` stay `=m` (olddefconfig keeps them modular — their
  selectors are `=m`), which is fine because the init script uses `modprobe`,
  not `insmod`. `depmod` recorded `g_ipod_audio → snd-pcm, snd-timer, snd`,
  and those modules are present in the image, so `modprobe g_ipod_audio`
  pulls the ALSA core automatically. `USB_CONFIGFS` / `USB_CONFIGFS_MASS_STORAGE`
  / `USB_F_MASS_STORAGE` / gadget symbols are all `=y` (built-in).
- `g_ipod_gadget.ko` and `g_ipod_hid.ko` have an **empty** `depends:` line —
  confirms the load order in `S50ipod-gadget` is genuinely required; nothing
  chains them.
- `modinfo` exposes `only_ipod` / `disable_audio` / `swap_configs` /
  `product_id`; `/etc/default/ipod-gadget` and `S50ipod-gadget` are in the
  image.

Still hardware-only: does the 2005 S40 actually enumerate the gadget and does
`/dev/iap0` behave (that needs the Phase 3 client to open it).

New/changed files:
`package/ipod-gadget/{Config.in,ipod-gadget.mk,ipod-gadget.hash}`,
`package/Config.in` (menu entry),
`configs/ipod_adapter_defconfig` (`BR2_PACKAGE_IPOD_GADGET=y`),
`board/ipod-adapter/rootfs_overlay/etc/init.d/S50ipod-gadget`,
`board/ipod-adapter/rootfs_overlay/etc/default/ipod-gadget`.

## Phase 3 — Package the iAP client

- [ ] Decide which fork (see open questions)
- [ ] `package/ipod/` using Buildroot's `golang-package` infra
- [ ] Confirm `BR2_TOOLCHAIN_SUPPORTS_PIE` with the Buildroot-built internal glibc toolchain (required for Go on ARM). Buildroot ships Go 1.23.
- [ ] Service that runs `ipod -d serve /dev/iap0` after modules load

## Phase 4 — Bridge the audio ⚠️ main remaining unknown

The car is USB host and owns the isochronous clock; the phone's A2DP stream has
its own. **Clock drift is guaranteed.** pipod never solved this cleanly — this is
the one piece with no known-good answer handed to us.

- [ ] `bluealsa` exposing the A2DP sink as an ALSA PCM
- [ ] `alsaloop` from bluealsa PCM → `hw:CARD=iPodUSB`, with rate adaptation enabled
- [ ] Tune buffer sizes against audible dropouts vs latency
- [ ] Confirm sample rate alignment (SBC is 44.1 kHz; check what `g_ipod_audio` UAC1 advertises)

**Gate:** phone plays → car speakers. This is "project works".

## Phase 5 — Metadata and controls

Everything above is audio-only.

- [ ] Track/artist out: BlueZ AVRCP exposes metadata on D-Bus (`org.bluez.MediaPlayer1`); feed into the client's `lingo-extremote` handler where it currently returns static values
- [ ] Media keys in: capture head-unit button presses with `ipod -d view trace.log`, map back to AVRCP commands via D-Bus
- [ ] Verify what the S40 display actually renders

## Phase 6 — Make it car-worthy

- [ ] Auto-reconnect to last-known phone on boot, with backoff (D8) — replaces the deleted `bluetooth-autoconnect`
- [ ] Boot time pass: `quiet`, `boot_delay=0`, `disable_splash=1`, strip kernel config
- [ ] Pairing mode trigger (see open questions) that flips `/var/lib/bluetooth` rw
- [ ] Strip the debug noise from `S98bluetootha2dp` — 375 lines of `echo` and fallback paths belongs in a bring-up script, not a boot service
- [ ] Survive repeated abrupt USB power loss without manual intervention
- [ ] Physical install: cable, mounting, power

---

## Open questions

- [ ] **Which `ipod` client fork?** `oandrew/ipod` (clean, static metadata) vs `geniass/ipod@playstatusnotification` (initial D-Bus metadata passthrough) vs `teostofell/ipod` (what the Ford user in #28 ran). Determines Phase 5 effort.
- [ ] **Pairing mode trigger** — GPIO button? Boot-time window? Only matters once the rw partition is normally mounted read-only.
- [ ] **Metadata scope** — is track/artist on the S40 display worth the custom Go work, or is audio-only enough?
- [x] Which `.hcd` firmware the Zero 2 W's chip actually wants (Zero W used `BCM43430A1.hcd`) — verify, don't assume. **Verified (web research, not on-device):** the Zero 2 W uses the same CYW43438/BCM43438 combo chip as the Zero W, and loads the same base firmware, `BCM43430A1.hcd`, via a board-specific alias `BCM43430A1.raspberrypi,model-zero-2-w.hcd` that the DT-bound driver resolves at runtime. `brcmfmac_sdio-firmware-rpi`'s `BR2_PACKAGE_BRCMFMAC_SDIO_FIRMWARE_RPI_BT` installs the whole `*.hcd` set unconditionally, so no Buildroot-side selection of a specific filename is needed or possible.

## Reference

| What | Where |
|---|---|
| Kernel modules (active, Aug 2025) | https://github.com/oandrew/ipod-gadget |
| iAP client daemon, Go (last touched 2021) | https://github.com/oandrew/ipod |
| Closest prior art — same idea, Raspbian | https://github.com/geniass/pipod |
| **Pi Zero 2 W + BT→iPod working**, Ford Sync 2 | [ipod-gadget#28](https://github.com/oandrew/ipod-gadget/issues/28) |
| Volvo V70 2015 *not* working (old commit, never retested) | [ipod-gadget#24](https://github.com/oandrew/ipod-gadget/issues/24) |
| Wiring the Pi to the car | [ipod-gadget#34](https://github.com/oandrew/ipod-gadget/issues/34) |
| Apple USB product IDs for `product_id=` | [doc/apple-usb.ids](https://github.com/oandrew/ipod-gadget/blob/master/doc/apple-usb.ids) |

### Module parameters worth knowing

- `only_ipod=1` — disable the mass-storage USB config
- `swap_configs=1` — reorder configs to `(ipod, mass_storage)`; helps when the dock only sees mass storage
- `product_id=0x1297` — advertise a different Apple model

### Hardware notes

- The car's USB goes to the Zero 2 W's **`USB` micro-B port, not `PWR IN`** — that's the OTG-capable one. The same cable carries power and data.
- Head units commonly drop USB power when switching sources (see #28) — hence D2/D3.
- A2DP is Bluetooth **Classic (BR/EDR)**. There is no BLE advertising involved; what makes the phone show it as a car stereo is the Class of Device plus page/inquiry scan and the A2DP-sink SDP record.

---

## Repo state

`1acfa94e` vendored Buildroot 2025.08 wholesale. Two commits of custom work on
top (`ca3d0f03`, `1bafdeed`) targeted the **Pi Zero W**, not the Zero 2 W, and
built `S98bluetootha2dp` around a PulseAudio that was never selected in the
defconfig. Phase 1 supersedes both.

Note `board/raspberrypi0w` and `board/raspberrypizero2w` are symlinks to
`board/raspberrypi`, so edits under `board/raspberrypi/` are shared across every
Pi board config in the tree.
