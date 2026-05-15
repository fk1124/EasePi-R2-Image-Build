# Configs

This directory keeps project-level build metadata that should be shared by
README tables, future dispatch scripts, CI jobs, and release automation.

Current files:

- `build-matrix.yaml`: the planned EasePi-R2 image matrix.

Rules:

- Keep distro/release/kernel/image-type combinations in the matrix first.
- Add implementation in one adapter layer at a time.
- Avoid hard-coding a new target in multiple shell scripts before it is listed here.
