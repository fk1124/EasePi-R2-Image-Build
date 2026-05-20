# Alpine Linux Rootfs

The Alpine target now has a reserved public command contract:

```bash
bash build-image.sh alpine stable 6.18 minimal
bash build-image.sh alpine stable 6.18 server
```

Current status:

- command routing is documented and wired through `build-image.sh`
- `build-alpine-image.sh` intentionally exits with TODO status
- the actual `apk` rootfs bootstrap is not implemented yet

Expected implementation direction:

- use Alpine `stable` arm64 minirootfs or apk static bootstrap tooling
- support `minimal` first, then `server`
- reuse the project BSP/kernel build where possible
- add Alpine-specific OpenRC service policy instead of reusing the Debian/Ubuntu systemd overlay directly
- reuse `scripts/40-pack-image.sh` for the final GPT/FAT32 boot/ext4 rootfs image layout where possible
