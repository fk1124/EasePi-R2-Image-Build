# Scripts

Current implemented BSP stages:

```text
00-env.sh           dependency and directory checks
10-build-bsp.sh     Armbian BSP package build
20-make-rootfs.sh   Debian rootfs bootstrap
20-make-alpine-rootfs.sh       Alpine minirootfs + apk package bootstrap
20-make-fedora-rootfs.sh       Fedora dnf installroot bootstrap
20-make-archlinuxarm-rootfs.sh Arch Linux ARM tarball + pacman bootstrap
30-install-bsp.sh   kernel, modules, boot files, account, and network install
30-install-portable-bsp.sh     non-dpkg BSP extraction and initramfs install
40-pack-image.sh    GPT image packing, U-Boot writing, compression
```

Future adapters should keep these boundaries:

- target routing belongs in `build-image.sh`
- distro rootfs policy belongs in `rootfs/<system>/`
- common validation belongs in small shared helpers
- image packing should stay parameter-driven
