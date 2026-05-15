# Rootfs Layout

Each system family gets its own directory under `rootfs/`.

```text
rootfs/debian/          Debian BSP packed-image rootfs, implemented
rootfs/ubuntu/          Ubuntu BSP packed-image rootfs, wired
rootfs/alpine/          Alpine Linux rootfs, reserved
rootfs/fedora/          Fedora rootfs, reserved
rootfs/archlinuxarm/    Arch Linux ARM rootfs, reserved
rootfs/kali/            Kali ARM rootfs, reserved
rootfs/fnos/            FNOS rootfs, reserved
rootfs/openwrt/         OpenWrt image integration, reserved
```

Keep distro package lists and source definitions here. Build stages should read
from this directory instead of embedding distro policy directly in shell code.
