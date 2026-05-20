# Project Structure

`EasePi-R2-Image-Build` is organized around one matrix and several adapters.

```text
build-image.sh                 Unified user-facing dispatcher
build.sh                       Native Armbian image adapter
build-bsp-image.sh             Debian / Ubuntu BSP packed-image adapter
build-alpine-image.sh          Alpine Linux command-contract adapter
configs/build-matrix.yaml      Project target matrix
rootfs/                        Distro rootfs definitions and package lists
scripts/                       Shared BSP build stages and future adapter helpers
userpatches/                   Armbian board, kernel, U-Boot, and overlay patches
output/                        BSP image outputs, ignored by Git
work/                          Temporary build workspace, ignored by Git
```

## Boundaries

- `build-image.sh` owns command normalization and target routing.
- `build.sh` owns native Armbian builds.
- `build-bsp-image.sh` owns Debian / Ubuntu BSP packed images that combine Armbian-built BSP packages with a distro rootfs.
- `build-alpine-image.sh` owns the Alpine command shape until the apk/OpenRC rootfs adapter is implemented.
- `rootfs/<system>/` owns package lists, source lists, and rootfs policy for one system family.
- `scripts/` should keep reusable build stages small and parameter-driven.
- `userpatches/` should stay focused on board enablement and kernel/U-Boot overlays.

## Expansion Rule

Add a target in this order:

1. Add or update the row in `configs/build-matrix.yaml`.
2. Add rootfs metadata under `rootfs/<system>/`.
3. Add the adapter script or extend an existing adapter.
4. Add the command to `README.md`.
5. Verify the target and then mark it implemented in the matrix.
