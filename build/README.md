# Build environment

Buildroot only runs on Linux, so builds happen inside a container. This
directory holds the container definition and a thin wrapper around Apple's
[`container`](https://github.com/apple/container) runtime.

## Quick start

```sh
./build/br setup        # create volumes and build the container image (once)
./build/br defconfig    # apply configs/ipod_adapter_defconfig
./build/br make         # full build -- first run takes a while, see below
./build/br images       # copy artifacts out to ./images/
```

Other subcommands:

```sh
./build/br make menuconfig       # any make target works
./build/br shell                 # interactive shell in the build env
./build/br shell -c 'grep BR2_PACKAGE_BLUEZ_ALSA /output/.config'
./build/br clean                 # reset output, KEEP the download cache
```

Resources default to 8 CPUs and 8 GB, leaving headroom on a 10-core / 16 GB
M1 Pro. Override per invocation:

```sh
BR_CPUS=4 BR_MEMORY=4g ./build/br make
```

## Why it is built this way

**Native aarch64, no emulation.** The defconfig uses a Buildroot-built internal
toolchain (`BR2_TOOLCHAIN_BUILDROOT_GLIBC`) rather than Bootlin's prebuilt one.
Bootlin is gated on `BR2_HOSTARCH = "x86_64"` because it ships x86_64 host
binaries, so on Apple Silicon it can never be selected — kconfig would silently
drop it and the build would fail confusingly, later. Building our own toolchain
costs roughly 20–40 minutes on the *first* build and nothing thereafter, and it
makes the build host-architecture independent, so the same commands work on a
Linux box or CI runner.

**Output lives in volumes, not the source tree.** Buildroot does an enormous
amount of small-file I/O. The repo is shared into the VM over virtiofs, which is
much slower than a native filesystem, so `/output` and the download cache
(`/dl`) are volumes. That is why artifacts need `./build/br images` to come back
out.

`./build/br clean` deliberately does not delete the download cache — that is
gigabytes of upstream tarballs.

**Buildroot refuses to run as root** by design. The image creates a `br` user
whose uid/gid are set at build time to match yours.

## Apple `container` notes

Verified against `container` CLI 1.2.2.

A few behaviours differ from other container runtimes and are worth knowing:

- **Each container gets its own lightweight VM.** There is no global machine to
  size — CPU and memory are allocated per `container run` via `--cpus` /
  `--memory`, which is what `BR_CPUS` / `BR_MEMORY` set.
- **Volumes must be given an explicit size at creation** (`container volume
  create -s 60G <name>`). They cannot grow on demand, so `setup` creates the
  output volume at 60G and the download cache at 20G.
- **New volumes are root-owned.** Since the image runs as `br`, `setup` performs
  a one-shot `container run -u root ... chown` to hand them over. Without the
  `-u root` override that chown runs as `br` and fails with
  `Operation not permitted`.
- **`container cp` copies from a container, not a volume**, so `br images`
  copies through the `/src` bind mount instead.

The runtime must be running (`container system status`); start it with
`container system start`.

## What is not verified here

The environment has been verified end to end: the image builds, volumes are
writable by the build user, the defconfig applies, and all 477 resolved symbols
match intent — including `BR2_PACKAGE_LIBSAMPLERATE` and the auto-selected
`BR2_TARGET_ROOTFS_CPIO`, with PulseAudio, python3 and ext2/4 confirmed absent.

A **full build has not been run**, so the Phase 1 gate (image boots on a Zero
2 W, phone pairs, A2DP sink appears) remains open. In particular the
`CONFIG_USB_*` symbols in `board/ipod-adapter/linux-usb-gadget.fragment` are
only checked against the kernel at build time.
