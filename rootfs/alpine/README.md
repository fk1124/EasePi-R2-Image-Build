# Alpine Linux Rootfs

The Alpine target is implemented through the portable BSP image path:

```bash
bash build-image.sh alpine stable 6.18 minimal
bash build-image.sh alpine stable 6.18 server
```

Current status:

- `build-image.sh` routes Alpine to `build-rootfs-image.sh`
- `scripts/20-make-alpine-rootfs.sh` downloads the official latest-stable aarch64 minirootfs and installs packages with `apk`
- `scripts/30-install-portable-bsp.sh` extracts the Armbian BSP debs, generates initramfs with `mkinitfs`, and writes RK3588 boot files
- Alpine uses OpenRC service defaults instead of the Debian/Ubuntu systemd overlay

Notes:

- `minimal` and `server` are supported.
- The default Alpine branch is `latest-stable`.
- Override the mirror with `ALPINE_MIRROR=https://...`.
