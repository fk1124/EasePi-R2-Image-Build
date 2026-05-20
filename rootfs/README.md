# Rootfs Layout

Each system family gets its own directory under `rootfs/`.

```text
rootfs/debian/          Debian BSP packed-image rootfs, implemented
rootfs/ubuntu/          Ubuntu BSP packed-image rootfs, wired
rootfs/alpine/          Alpine Linux apk rootfs, implemented
rootfs/fedora/          Fedora dnf installroot rootfs, implemented
rootfs/archlinuxarm/    Arch Linux ARM pacman rootfs, implemented
rootfs/kali/            Kali ARM debootstrap rootfs, implemented
rootfs/fnos/            FNOS rootfs, reserved
rootfs/openwrt/         OpenWrt 24/25 custom 6.18 profile, designed
```

Keep distro package lists and source definitions here. Build stages should read
from this directory instead of embedding distro policy directly in shell code.
