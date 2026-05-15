# Build Result: armbian bookworm 6.1 minimal

- Build date: 2026-05-16
- Build host: 192.168.99.99
- Source commit: c3a5067a64f09b210e95b0984793754465650161
- Command: `CPUTHREADS=24 ARMBIAN_BUILD_DIR=/root/rk3588_build/build bash build-image.sh armbian bookworm 6.1 minimal`
- Armbian options: `BOARD=easepi-r2 BRANCH=vendor BUILD_DESKTOP=no BUILD_MINIMAL=yes CLEAN_LEVEL=make-kernel,make-uboot CPUTHREADS=24 RELEASE=bookworm SKIP_ORAS=yes USE_CCACHE=yes`
- Runtime: 22:27 min
- Exit code: 0

## Output

- Raw image: `Armbian-unofficial_26.05.0-trunk_Easepi-r2_bookworm_vendor_6.1.115_minimal.img`
- Raw image size: 2164260864 bytes
- Raw SHA256: `23a436969d903e6ebad34bf33379197da87d32180fb08815e8652775e4b76378`
- Local compressed archive: `Armbian-unofficial_26.05.0-trunk_Easepi-r2_bookworm_vendor_6.1.115_minimal.img.xz`
- Local compressed archive size: 321349196 bytes
- Local compressed archive SHA256: `e600aa07db915f372b4acf6b491881646c3500af7dc9d3e39bcf08d4021843fb`
- GitHub Release assets intentionally exclude the image archive; image files are retained on the build host.

## Validation

- Build wrapper exit code was `0`.
- Raw image checksum verified with `sha256sum -c`.
- Release archive integrity verified with `xz -t`.
- Partition table detected as GPT with `bootfs` FAT16 and `rootfs` ext4 partitions.
- Read-only filesystem checks passed for both partitions.

## Notes

- ORAS reported two `denied` cache lookup warnings during the build. They were non-fatal; the build fell back to local artifact generation and completed successfully.
