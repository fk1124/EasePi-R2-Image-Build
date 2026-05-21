# OpenWrt

This directory defines the OpenWrt command contract and the first custom profile
for EasePi R2.

Supported matrix targets:

- `24`: OpenWrt 24 userland, custom kernel 6.18
- `25`: OpenWrt 25 userland, custom kernel 6.18

These targets intentionally diverge from upstream OpenWrt release kernels. The
OpenWrt release controls userland and package feeds; the kernel is the
project-pinned 6.18 RK3588 feature line for EasePi R2 GPU/NPU/VPU/KVM/LXC work.

OpenWrt should be integrated as its own image path rather than sharing the
Debian/Ubuntu BSP rootfs stages.

## Final command shape

The public entry stays aligned with the rest of this repository:

```bash
bash build-image.sh openwrt <24|25> 6.18 <squashfs|ext4>
```

The max feature set is selected by profile environment variables:

```bash
OPENWRT_PROFILE=rk3588-max \
OPENWRT_KMOD_STRATEGY=build-all-preinstall-max \
bash build-image.sh openwrt 25 6.18 ext4
```

By default this profile does not require a local modified kernel tree. The
adapter pins OpenWrt to the 6.18 kernel line and lets OpenWrt download the
matching upstream kernel tarball, starting with `linux-6.18.tar.xz`.

If you later prepare a vendor or self-maintained `linux-6.18.x` tree, pass it
explicitly:

```bash
OPENWRT_KERNEL_TREE=/path/to/linux-6.18.x \
OPENWRT_PROFILE=rk3588-max \
OPENWRT_KMOD_STRATEGY=build-all-preinstall-max \
bash build-image.sh openwrt 25 6.18 ext4
```

Set `OPENWRT_KERNEL_TREE=auto` only when you want the adapter to search this
repo's work/cache directories for an existing tree.

The adapter defaults `OPENWRT_KERNEL_HASH=skip` for 6.18 bring-up so OpenWrt can
download a kernel tarball before the final hash is pinned. For reproducible
builds, pass the exact kernel tarball version and hash:

```bash
OPENWRT_KERNEL_VERSION=6.18 \
OPENWRT_KERNEL_HASH=9106a4605da9e31ff17659d958782b815f9591ab308d03b0ee21aad6c7dced4b \
OPENWRT_PROFILE=rk3588-max \
OPENWRT_KMOD_STRATEGY=build-all-preinstall-max \
bash build-image.sh openwrt 25 6.18 ext4
```

For a newer stable kernel tarball, override both values:

```bash
OPENWRT_KERNEL_VERSION=6.18.32 \
OPENWRT_KERNEL_HASH=<sha256> \
OPENWRT_PROFILE=rk3588-max \
OPENWRT_KMOD_STRATEGY=build-all-preinstall-max \
bash build-image.sh openwrt 25 6.18 ext4
```

Without a local RK3588 vendor kernel tree, GPU/NPU/VPU enablement is best-effort:
the profile enables the kernel symbols and preinstalls userspace/kmod choices
where OpenWrt feeds provide them, while board-specific acceleration may still
need a later RK3588 patch stack.

When building from a root shell, the adapter defaults
`OPENWRT_FORCE_UNSAFE_CONFIGURE=auto` and exports `FORCE_UNSAFE_CONFIGURE=1`.
This avoids GNU tar's configure-time root guard during `tools/tar/compile`.
Set `OPENWRT_FORCE_UNSAFE_CONFIGURE=no` to disable the workaround, or build as a
normal user when you want the cleanest OpenWrt build environment.

Recommended commands:

```bash
# OpenWrt 25, writable image for Docker/LXC/redroid/KVM experiments.
OPENWRT_PROFILE=rk3588-max OPENWRT_KMOD_STRATEGY=build-all-preinstall-max bash build-image.sh openwrt 25 6.18 ext4

# OpenWrt 25, router-style immutable rootfs plus overlay.
OPENWRT_PROFILE=rk3588-max OPENWRT_KMOD_STRATEGY=build-all-preinstall-max bash build-image.sh openwrt 25 6.18 squashfs

# OpenWrt 24, writable compatibility baseline.
OPENWRT_PROFILE=rk3588-max OPENWRT_KMOD_STRATEGY=build-all-preinstall-max bash build-image.sh openwrt 24 6.18 ext4

# OpenWrt 24, router-style compatibility baseline.
OPENWRT_PROFILE=rk3588-max OPENWRT_KMOD_STRATEGY=build-all-preinstall-max bash build-image.sh openwrt 24 6.18 squashfs
```

Use `ext4` for the heavy lab image because Docker, LXC, redroid, and VM disk
images need writable space. Use `squashfs` when the device is mainly a router
and you want OpenWrt's normal immutable-root workflow.

## rk3588-max profile

Profile files:

- `profiles/rk3588-max.env`: profile metadata and default strategy
- `packages/rk3588-max.txt`: desired preinstalled packages and kmods
- `kernel/rk3588-max.fragment`: desired Linux 6.18 kernel feature fragment

The package list uses two prefixes:

- `!pkg`: required package; the adapter warns if unavailable after `defconfig`
- `?pkg`: best-effort package; install when available from feeds or local kmod repo

Set `OPENWRT_STRICT_REQUIRED_PACKAGES=yes` to turn missing required packages
into a hard error.

The kmod strategy means:

- build a matching local kmod repository for the exact 6.18 kernel build
- preinstall the curated max set into the image
- keep extra kmods available for later installation from the matching local feed

This matters because OpenWrt kmods must match the running kernel ABI. After a
kernel change, old remote kmods are not a reliable fallback; the image should
carry or publish its own matching module feed.

## Feature targets

The `rk3588-max` profile is designed to enable as much as is practical for:

- RK3588 GPU display/compute drivers, VPU decode/encode path, RGA, DMA-BUF, NPU
- KVM, VFIO, virtio, future RouterOS VM experiments
- LXC, Docker, and redroid prerequisites
- WireGuard/OpenVPN/IPsec/Tailscale/ZeroTier style VPN use
- USB 4G/5G modems, QMI/MBIM, USB serial adapters
- Bluetooth, Wi-Fi, HID/input, IR receiver support
- ext4/btrfs/f2fs/exfat/NFS/CIFS/FUSE storage workloads

## Adapter behavior

`build-openwrt-image.sh` now:

1. clone or reuse the selected OpenWrt release tree
2. inject the EasePi R2 target/DTS and pin the custom 6.18 kernel line
3. merge `kernel/rk3588-max.fragment`
4. inject an EasePi R2 U-Boot profile unless `OPENWRT_BUILD_UBOOT=no`
5. resolve `packages/rk3588-max.txt` into required and best-effort packages
6. build the image plus a matching local kmod feed
7. emit firmware, manifest, checksums, buildinfo files, and the local kmod repo

Useful test modes:

```bash
# Validate the command contract without cloning/building.
EASEPI_R2_DRY_RUN=yes OPENWRT_PROFILE=rk3588-max bash build-image.sh openwrt 25 6.18 ext4

# Clone/patch/feed/defconfig only; useful before a full world build.
OPENWRT_CONFIG_ONLY=yes OPENWRT_PROFILE=rk3588-max bash build-image.sh openwrt 25 6.18 ext4
```
