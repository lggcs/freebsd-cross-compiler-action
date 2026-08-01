#!/usr/bin/env bash
# build_sysroot.sh — Transparent, auditable FreeBSD sysroot builder
#
# This script downloads official FreeBSD distribution archives directly from
# download.freebsd.org, verifies them against the official MANIFEST checksums,
# and extracts a minimal sysroot suitable for cross-compilation.
#
# Every input is from an official FreeBSD source. Every checksum is verified.
# The output hash is published for downstream verification.
#
# Usage:
#   ./build_sysroot.sh <freebsd-version> <arch> [output-dir]
#
# Examples:
#   ./build_sysroot.sh 15.1-RELEASE amd64
#   ./build_sysroot.sh 14.3-RELEASE amd64 /tmp/output
#
# Outputs:
#   freebsd-sysroot-<version>-<arch>.tar.zst  — the sysroot tarball
#   freebsd-sysroot-<version>-<arch>.txt      — build provenance & verification log
#
# Requirements: curl, tar, zstd, sha256sum, root privileges (for tar extraction
# with proper ownership). On ubuntu-latest this runs via sudo.
set -euo pipefail

VERSION="${1:-15.1-RELEASE}"
ARCH="${2:-amd64}"
OUTPUT_DIR="${3:-.}"

FREEBSD_MIRROR="https://download.freebsd.org"
RELEASE_URL="${FREEBSD_MIRROR}/releases/${ARCH}/${VERSION}"

STAGING="$(mktemp -d /tmp/sysroot-build.XXXXXX)"
SYSROOT_NAME="freebsd-sysroot-$(echo "$VERSION" | sed 's/-RELEASE$//')-${ARCH}"
ROOT="${STAGING}/${SYSROOT_NAME}"

trap 'rm -rf "${STAGING}"' EXIT INT TERM

log()   { echo "[build_sysroot] $*"; }
fail()  { echo "ERROR: $*" >&2; exit 1; }

# ── Step 1: Fetch and verify the official MANIFEST ───────────────────
log "Fetching official FreeBSD ${VERSION} (${ARCH}) MANIFEST"
MANIFEST_URL="${RELEASE_URL}/MANIFEST"
MANIFEST_FILE="${STAGING}/MANIFEST"
curl -sSL -o "$MANIFEST_FILE" "$MANIFEST_URL"
[ -s "$MANIFEST_FILE" ] || fail "Could not download MANIFEST from ${MANIFEST_URL}"

# Verify MANIFEST is valid (has expected fields)
grep -q '^base\.txz' "$MANIFEST_FILE" || fail "MANIFEST does not contain base.txz entry — invalid or wrong format"
log "MANIFEST downloaded and validated"

# Extract base.txz hash from MANIFEST
BASE_TXZ_HASH=$(grep '^base\.txz' "$MANIFEST_FILE" | cut -f2)
log "Official base.txz SHA-256: ${BASE_TXZ_HASH}"

# ── Step 2: Download base.txz ────────────────────────────────────────
log "Downloading base.txz from ${RELEASE_URL}/base.txz"
BASE_TXZ="${STAGING}/base.txz"
if [ -f "${BASE_TXZ}" ]; then
    log "  base.txz already present in staging, skipping download"
else
    curl -sSL -o "$BASE_TXZ" "${RELEASE_URL}/base.txz"
fi
[ -s "$BASE_TXZ" ] || fail "base.txz download failed"

# ── Step 3: Verify base.txz against MANIFEST ──────────────────────────
log "Verifying base.txz against official MANIFEST checksum"
ACTUAL_HASH=$(sha256sum "$BASE_TXZ" | cut -d' ' -f1)
if [ "$ACTUAL_HASH" != "$BASE_TXZ_HASH" ]; then
    fail "base.txz SHA-256 mismatch!
  Expected (from MANIFEST): ${BASE_TXZ_HASH}
  Actual:                  ${ACTUAL_HASH}"
fi
log "base.txz verified: SHA-256 ${ACTUAL_HASH}"

# ── Step 4: Extract base.txz into sysroot staging ────────────────────
log "Extracting base.txz into sysroot staging directory"
mkdir -p "$ROOT"

# base.txz is a tarball that extracts into ./usr/, ./lib/, ./libexec/, etc.
# We only need headers, static libs, shared libs, CRT objects, and the
# dynamic linker — NOT the full base system (no binaries, no config, etc.)
#
# Extract to a temporary extraction point, then copy only what we need.
# SCHILY.fflags warnings are expected: Linux tar doesn't understand FreeBSD
# file flags — they don't affect headers, libs, or CRT objects.
EXTRACT_DIR="${STAGING}/extracted"
mkdir -p "$EXTRACT_DIR"
tar -xJf "$BASE_TXZ" -C "$EXTRACT_DIR" 2>&1 | grep -v 'SCHILY.fflags' || true

# ── Step 5: Assemble minimal sysroot ──────────────────────────────────
log "Assembling minimal sysroot"

# Headers — all of /usr/include
mkdir -p "${ROOT}/usr/include"
cp -a "${EXTRACT_DIR}/usr/include/." "${ROOT}/usr/include/" 2>/dev/null || true
log "  Copied /usr/include ($(du -sh "${ROOT}/usr/include" | cut -f1))"

# Static libraries and CRT objects
mkdir -p "${ROOT}/usr/lib"
for f in "${EXTRACT_DIR}/usr/lib"/*.a "${EXTRACT_DIR}/usr/lib"/*.o "${EXTRACT_DIR}/usr/lib"/*.po; do
    [ -f "$f" ] && cp "$f" "${ROOT}/usr/lib/"
done
log "  Copied /usr/lib/*.a, *.o ($(du -sh "${ROOT}/usr/lib" | cut -f1))"

# Shared libraries from /lib
mkdir -p "${ROOT}/lib"
for f in "${EXTRACT_DIR}/lib"/*.so.* "${EXTRACT_DIR}/lib"/*.so; do
    [ -f "$f" ] && cp "$f" "${ROOT}/lib/"
done 2>/dev/null || true
log "  Copied /lib/*.so ($(du -sh "${ROOT}/lib" | cut -f1))"

# Shared libraries from /usr/lib (e.g., libprivatellvm.so)
for f in "${EXTRACT_DIR}/usr/lib"/*.so.* "${EXTRACT_DIR}/usr/lib"/*.so; do
    [ -f "$f" ] && cp "$f" "${ROOT}/usr/lib/"
done 2>/dev/null || true

# Dynamic linker
mkdir -p "${ROOT}/libexec"
if [ -f "${EXTRACT_DIR}/libexec/ld-elf.so.1" ]; then
    cp "${EXTRACT_DIR}/libexec/ld-elf.so.1" "${ROOT}/libexec/"
    log "  Copied /libexec/ld-elf.so.1"
else
    fail "Dynamic linker ld-elf.so.1 not found in base.txz"
fi

# pkgconfig files
if [ -d "${EXTRACT_DIR}/usr/libdata/pkgconfig" ]; then
    mkdir -p "${ROOT}/usr/libdata/pkgconfig"
    cp -a "${EXTRACT_DIR}/usr/libdata/pkgconfig/." "${ROOT}/usr/libdata/pkgconfig/"
    log "  Copied /usr/libdata/pkgconfig ($(du -sh "${ROOT}/usr/libdata/pkgconfig" | cut -f1))"
fi

# Symlink libexec for dynamic linker resolution
if [ ! -e "${ROOT}/usr/libexec/ld-elf.so.1" ]; then
    mkdir -p "${ROOT}/usr/libexec"
    ln -s ../../libexec/ld-elf.so.1 "${ROOT}/usr/libexec/ld-elf.so.1"
fi

# ── Step 6: Write provenance metadata ─────────────────────────────────
SYSROOT_HASH_FILE="${STAGING}/sysroot-hash.txt"
log "Writing provenance and verification metadata"

{
    echo "${SYSROOT_NAME}"
    echo "source: Official FreeBSD ${VERSION} (${ARCH}) base.txz"
    echo "source_url: ${RELEASE_URL}/base.txz"
    echo "manifest_url: ${MANIFEST_URL}"
    echo "base_txz_sha256: ${BASE_TXZ_HASH}"
    echo "freebsd_gitrev: $(curl -sSL "${RELEASE_URL}/REVISION" 2>/dev/null || echo 'unknown')"
    echo "built_with: build_sysroot.sh v1.0.0"
    echo "built_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "contents: headers, static libs, shared libs, crt objects, dynamic linker, pkgconfig"
    echo ""
    echo "Verification log:"
    echo "  [PASS] MANIFEST downloaded from ${MANIFEST_URL}"
    echo "  [PASS] base.txz SHA-256 matches MANIFEST: ${BASE_TXZ_HASH}"
    echo "  [INFO] Sysroot assembled from verified base.txz"
} > "${ROOT}/SYSROOT.txt"

# ── Step 7: Create tarball ───────────────────────────────────────────
TARBALL_NAME="${SYSROOT_NAME}.tar.zst"
TARBALL_PATH="${OUTPUT_DIR}/${TARBALL_NAME}"
mkdir -p "$OUTPUT_DIR"

log "Creating ${TARBALL_NAME}"
tar --zstd -cf "${TARBALL_PATH}" -C "${STAGING}" "${SYSROOT_NAME}/"

SYSROOT_TAR_HASH=$(sha256sum "${TARBALL_PATH}" | cut -d' ' -f1)
TARBALL_SIZE=$(ls -lh "${TARBALL_PATH}" | awk '{print $5}')

log "Done: ${TARBALL_PATH} (${TARBALL_SIZE})"
log "Sysroot tarball SHA-256: ${SYSROOT_TAR_HASH}"

# ── Step 8: Write CHECKSUMS file ─────────────────────────────────────
CHECKSUMS_FILE="${OUTPUT_DIR}/CHECKSUMS-$(echo "$VERSION" | sed 's/-RELEASE$//').txt"
log "Writing ${CHECKSUMS_FILE}"
{
    echo "# FreeBSD Cross-Compiler Action — Sysroot Checksums"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# FreeBSD Version: ${VERSION}"
    echo "# Architecture: ${ARCH}"
    echo "# Source: Official base.txz from download.freebsd.org"
    echo ""
    echo "# File                         SHA-256"
    echo "${SYSROOT_TAR_HASH}  ${TARBALL_NAME}"
    echo "${BASE_TXZ_HASH}  base.txz (upstream source, verified against MANIFEST)"
} > "$CHECKSUMS_FILE"

# Also write SYSROOT.txt to the output directory as a standalone provenance file
# (it is packed inside the tarball, but also useful on disk for CI summaries)
cp "${ROOT}/SYSROOT.txt" "${OUTPUT_DIR}/${SYSROOT_NAME}-SYSROOT.txt"

log ""
log "══════════════════════════════════════════════════════════════════"
log " Sysroot build complete"
log "   Output:     ${TARBALL_PATH}"
log "   Size:       ${TARBALL_SIZE}"
log "   SHA-256:    ${SYSROOT_TAR_HASH}"
log "   Checksums:  ${CHECKSUMS_FILE}"
log "   Source:     ${RELEASE_URL}/base.txz (official FreeBSD)"
log "   Verified:   base.txz SHA-256 matches MANIFEST"
log "══════════════════════════════════════════════════════════════════"