# Kali ARM Rootfs

Kali ARM is implemented through the Debian-family BSP image path:

```bash
bash build-image.sh kali rolling 6.18 minimal
bash build-image.sh kali rolling 6.18 server
```

Current implementation:

- `scripts/20-make-rootfs.sh` supports `DIST=kali` with `kali-rolling` debootstrap.
- Kali keeps its own package lists and `sources/rolling.list`.
- `scripts/30-install-bsp.sh` installs the Armbian BSP debs with `dpkg`, then generates Debian-family boot files.
- If the host lacks `kali-archive-keyring`, bootstrap falls back to `--no-check-gpg` for the first stage and installs the keyring inside the rootfs.
