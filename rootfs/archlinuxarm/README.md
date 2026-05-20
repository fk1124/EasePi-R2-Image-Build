# Arch Linux ARM Rootfs

Arch Linux ARM is implemented through the portable BSP image path:

```bash
bash build-image.sh archlinuxarm rolling 6.18 minimal
bash build-image.sh archlinuxarm rolling 6.18 server
```

Current implementation:

- `scripts/20-make-archlinuxarm-rootfs.sh` downloads the official generic AArch64 rootfs tarball.
- Packages are installed/updated with `pacman` inside the aarch64 chroot.
- `scripts/30-install-portable-bsp.sh` extracts the Armbian BSP debs, generates initramfs with `mkinitcpio`, and writes RK3588 boot files.
- Arch Linux ARM uses systemd-networkd and the project systemd overlay.

Host recommendation:

```bash
sudo apt install -y libarchive-tools
```

The script can fall back to GNU `tar` if `bsdtar` is unavailable.
