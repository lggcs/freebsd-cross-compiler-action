# FreeBSD Cross Compiler Action

Cross-compile C/C++/CMake projects to **FreeBSD 15.1 (amd64)** directly on `ubuntu-latest` — no Docker, no VM, no QEMU. Uses LLVM/Clang native cross-compilation with a prebuilt FreeBSD sysroot.

## Why This Action?

| Traditional Approach | This Action |
|---|---|
| Spin up a FreeBSD VM | Runs natively on `ubuntu-latest` |
| Install FreeBSD, ports, build tools | Just use clang + lld + sysroot |
| QEMU emulation (slow) | Native cross-compile (fast) |
| Docker-in-Docker | No Docker needed |
| Minutes of setup | Seconds |

## How It Works

LLVM's native cross-compilation: **Clang** on the Linux host compiles source targeting `x86_64-unknown-freebsd15.1`, **LLD** links against a prebuilt **FreeBSD sysroot** (headers, libs, CRT objects, dynamic linker). The output is a native FreeBSD ELF binary — no QEMU, no VM.

## Quick Start

```yaml
# .github/workflows/build-freebsd.yml
name: Build for FreeBSD

on: [push, pull_request]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Cross-compile to FreeBSD
        uses: lggcs/freebsd-cross-compiler-action@v1
        with:
          command: |
            cmake -B build-freebsd $FREEBSD_CMAKE_FLAGS
            cmake --build build-freebsd

      - name: Upload FreeBSD binary
        uses: actions/upload-artifact@v5
        with:
          name: freebsd-binaries
          path: build-freebsd/
```

## Inputs

| Input | Description | Required | Default |
|-------|-------------|----------|---------|
| `command` | Build command to run after environment setup | no | `''` |
| `working-directory` | Working directory for the build command | no | `.` |
| `cflags` | Extra C compiler flags | no | `''` |
| `cxxflags` | Extra C++ compiler flags | no | `''` |
| `ldflags` | Extra linker flags | no | `''` |
| `output-dir` | Build output directory (also SBOM location) | no | `build-freebsd` |
| `debug` | Enable verbose diagnostics | no | `false` |
| `target` | LLVM target triple | no | `x86_64-unknown-freebsd15.1` |
| `sysroot-version` | FreeBSD release (e.g., `15.1-RELEASE`) | no | `15.1-RELEASE` |
| `sysroot-arch` | Sysroot architecture (`amd64`) | no | `amd64` |
| `custom-sysroot-url` | Override sysroot download URL (your own audited, signed storage) | no | `''` |
| `custom-sysroot-sha256` | Expected SHA-256 of custom sysroot tarball | no | `''` |
| `verify-sysroot` | Verification mode (`sha256`, `manifest`, `false`) | no | `false` |
| `generate-sbom` | Generate SBOM (CycloneDX/SPDX) | no | `false` |
| `sbom-format` | `cyclonedx`, `spdx`, or `both` | no | `both` |
| `package-output` | Wrap binary into FreeBSD `.pkg` file | no | `false` |

## Outputs

| Output | Description |
|--------|-------------|
| `sysroot-path` | Absolute path to the extracted FreeBSD sysroot |
| `cc` | Path to the cross C compiler wrapper |
| `cxx` | Path to the cross C++ compiler wrapper |
| `target` | LLVM target triple |
| `toolchain-file` | Path to CMake toolchain file |
| `sysroot-sha256` | SHA-256 of the sysroot tarball used (audit trail) |
| `sbom-cyclonedx` | Path to CycloneDX SBOM (if enabled) |
| `sbom-spdx` | Path to SPDX SBOM (if enabled) |
| `pkg-path` | Path to FreeBSD `.pkg` file (if enabled) |

## Usage Examples

### Simple C Project (Make)

```yaml
- uses: lggcs/freebsd-cross-compiler-action@v1
  with:
    command: make
```

`CC` and `CXX` are automatically set to the cross-compiler wrappers — Make picks them up automatically.

### CMake Project

```yaml
- uses: lggcs/freebsd-cross-compiler-action@v1
  with:
    command: |
      cmake -B build-freebsd $FREEBSD_CMAKE_FLAGS
      cmake --build build-freebsd
```

`$FREEBSD_TOOLCHAIN_FILE` and `$FREEBSD_CMAKE_FLAGS` are set automatically.

### C++ Project with Custom Flags

```yaml
- uses: lggcs/freebsd-cross-compiler-action@v1
  with:
    command: |
      cmake -B build-freebsd $FREEBSD_CMAKE_FLAGS -DCMAKE_BUILD_TYPE=Release
      cmake --build build-freebsd
    cxxflags: '-O2 -Wall -Wextra'
```

### Setup Only (No Build Command)

```yaml
- uses: lggcs/freebsd-cross-compiler-action@v1
# CC, CXX, CFLAGS, CXXFLAGS, FREEBSD_SYSROOT, etc. are set in the environment
- name: Custom build
  run: |
    $CC -o myapp main.c
    $CXX -o myapp-cpp main.cpp
```

## Custom Sysroot

If you maintain your own audited, signed sysroot in internal storage, point the Action at it:

```yaml
- uses: lggcs/freebsd-cross-compiler-action@v1
  with:
    custom-sysroot-url: 'https://artifacts.enterprise.com/freebsd-sysroot-15.1-amd64.tar.zst'
    custom-sysroot-sha256: 'a1b2c3d4e5f6...'
    verify-sysroot: 'sha256'
    command: make
```

## Transparent Sysroot Build Pipeline

For maximum trust, the sysroot build process is **fully open-source and auditable**:

1. **`scripts/build_sysroot.sh`** downloads `base.txz` directly from [download.freebsd.org](https://download.freebsd.org), verifies it against the official `MANIFEST` checksums, and extracts a minimal sysroot.

2. **`.github/workflows/build_sysroot.yml`** runs this script as a **public GitHub Action** every time FreeBSD releases a patch, publishing the sysroot and `CHECKSUMS` file as GitHub Release assets.

3. **SHA-256 checksums** are published alongside every release for downstream verification.

Security teams can:
- Audit `build_sysroot.sh` — every input is from official FreeBSD sources
- Verify the published checksums against the FreeBSD MANIFEST
- Pin a specific sysroot version using `verify-sysroot: 'manifest'` to check the tarball hash against the official FreeBSD MANIFEST at compile time

### Manifest Verification

```yaml
- uses: lggcs/freebsd-cross-compiler-action@v1
  with:
    verify-sysroot: 'manifest'
    command: make
```

This downloads the official FreeBSD `MANIFEST` from `download.freebsd.org`, verifies the `base.txz` SHA-256 in it, then checks the sysroot tarball hash against the published `CHECKSUMS` file. Full provenance is recorded for audit trails.

## SBOM Generation

```yaml
- uses: lggcs/freebsd-cross-compiler-action@v1
  with:
    command: |
      cmake -B build-freebsd $FREEBSD_CMAKE_FLAGS
      cmake --build build-freebsd
    generate-sbom: true
    sbom-format: both
```

SBOM files are written to `build-freebsd/sbom/`:
- `sbom.cyclonedx.json` — CycloneDX 1.5 format
- `sbom.spdx` — SPDX 2.3 format

## FreeBSD .pkg Packaging

```yaml
- uses: lggcs/freebsd-cross-compiler-action@v1
  with:
    command: make
    package-output: true
```

Wraps compiled ELF binaries into a FreeBSD `.pkg` package with manifest, checksums, and mtree directory specification.

## Technical Details

### Toolchain

- **Compiler**: LLVM/Clang 17+ — installed on `ubuntu-latest` via `apt`
- **Linker**: LLD — required because GNU `ld` cannot link cross-target objects
- **Target triple**: `x86_64-unknown-freebsd15.1`
- **C++ ABI**: FreeBSD's libc++ / libcxxrt (included in sysroot)

### Sysroot

The sysroot (210 MB compressed, 623 MB extracted) contains:
- `/usr/include/` — FreeBSD system headers
- `/usr/lib/` — static libraries, CRT objects (crt1.o, crti.o, crtbegin.o, etc.)
- `/lib/` — shared libraries (libc.so, libm.so, libthr.so, etc.)
- `/libexec/ld-elf.so.1` — FreeBSD dynamic linker
- `/usr/libdata/pkgconfig/` — pkg-config files

Built transparently by `scripts/build_sysroot.sh` from official FreeBSD `base.txz` (downloaded from download.freebsd.org, SHA-256 verified against the official MANIFEST). The full build pipeline runs as a public GitHub Action (`.github/workflows/build_sysroot.yml`).

### Compiler Wrappers

The Action creates wrapper scripts that encapsulate:
- The target triple (`--target=x86_64-unknown-freebsd15.1`)
- The sysroot path (`--sysroot=...`)
- The linker (`-fuse-ld=lld`)
- For C++: `-stdlib=libc++ -lc++ -lcxxrt` (needed because clang's FreeBSD target config doesn't auto-link libc++ in this native-cross setup)

Exported as `CC`/`CXX` so Make, CMake, and other build systems pick them up automatically.

### CMake Toolchain File

Generated at setup time, sets `CMAKE_SYSTEM_NAME=FreeBSD`, compiler paths, and `CMAKE_FIND_ROOT_PATH` to the sysroot. Exposed via `$FREEBSD_TOOLCHAIN_FILE` and `$FREEBSD_CMAKE_FLAGS`.

## License

- Action source code: MIT License
- FreeBSD sysroot: BSD 2-Clause License (derived from FreeBSD 15.1-RELEASE)

## Contributing

Contributions welcome! Please open an issue or submit a pull request.

### Development

```bash
# Build a sysroot from official FreeBSD sources (auditable)
bash scripts/build_sysroot.sh 15.1-RELEASE amd64

# Test cross-compilation
clang --target=x86_64-unknown-freebsd15.1 --sysroot=./freebsd-sysroot-15.1-amd64 -fuse-ld=lld -o hello hello.c
clang --target=x86_64-unknown-freebsd15.1 --sysroot=./freebsd-sysroot-15.1-amd64 -fuse-ld=lld -stdlib=libc++ -o hello hello.cpp -lc++ -lcxxrt
```