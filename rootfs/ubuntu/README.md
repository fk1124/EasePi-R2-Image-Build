# Ubuntu Rootfs

Ubuntu BSP packed images use `debootstrap` with the Ubuntu ports archive.

Planned and wired releases:

- `jammy`: Ubuntu 22.04 LTS
- `noble`: Ubuntu 24.04 LTS
- `resolute`: Ubuntu 26.04 LTS preview

Package profiles are intentionally separate from Debian:

- `packages-minimal.txt`
- `packages-server.txt`
- `packages-desktop.txt`

Keep Ubuntu package names, apt sources, desktop profiles, and first-boot policy
isolated here so Debian BSP builds do not inherit Ubuntu-specific changes.
