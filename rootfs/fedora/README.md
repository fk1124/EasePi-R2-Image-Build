# Fedora Rootfs

Fedora is implemented through the portable BSP image path:

```bash
bash build-image.sh fedora latest 6.18 minimal
bash build-image.sh fedora latest 6.18 server
```

Current implementation:

- `scripts/20-make-fedora-rootfs.sh` creates an aarch64 installroot with `dnf`/`dnf5`.
- The default tracked Fedora version is `44`; override it with `FEDORA_VERSION=44`.
- `scripts/30-install-portable-bsp.sh` extracts the Armbian BSP debs, generates initramfs with `dracut`, and writes RK3588 boot files.
- Fedora uses systemd-networkd and the project systemd overlay.

Host dependency:

```bash
sudo apt install -y dnf
```
