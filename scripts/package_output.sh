#!/usr/bin/env bash
# package_output.sh — Wrap compiled binaries into a FreeBSD .pkg package
#
# Produces a .pkg file following the FreeBSD pkg format:
#   - Archive: tar with zstd compression (tzst — the modern pkg default)
#   - +MANIFEST: UCL format manifest with all required fields
#   - +MTREE_DIRS: mtree specification for directory structure
#   - Payload files: staged relative to prefix (/usr/local)
#
# Reference: FreeBSD Porter's Handbook + pkg-create(8)
set -euo pipefail

OUTPUT_DIR="${INPUT_OUTPUT_DIR:-build-freebsd}"
WORKSPACE="${WORKSPACE:-$(pwd)}"
DEBUG="${INPUT_DEBUG:-false}"
TARGET="${FREEBSD_TARGET:-x86_64-unknown-freebsd15.1}"
SYSROOT="${FREEBSD_SYSROOT:-}"

# Derive FreeBSD major version from target triple (x86_64-unknown-freebsd15.1 → 15)
FREEBSD_MAJOR=$(echo "$TARGET" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1)
[ -n "$FREEBSD_MAJOR" ] || FREEBSD_MAJOR=15

# Derive FreeBSD arch from target (x86_64 → amd64, aarch64 → aarch64)
case "$TARGET" in
    *x86_64*)    PKG_ARCH="amd64" ;;
    *aarch64*)   PKG_ARCH="aarch64" ;;
    *armv7*)     PKG_ARCH="armv7" ;;
    *i386*)      PKG_ARCH="i386" ;;
    *riscv64*)   PKG_ARCH="riscv64" ;;
    *powerpc64*) PKG_ARCH="powerpc64" ;;
    *)           PKG_ARCH="amd64" ;;
esac

# The abi field format: freebsd:MAJOR:ARCH
PKG_ABI="freebsd:${FREEBSD_MAJOR}:${PKG_ARCH}"

debug_log() { if [ "$DEBUG" = "true" ] || [ "$DEBUG" = "True" ]; then echo "[freebsd-cross] DEBUG: $*"; fi; }
fail() { echo "::error::$*"; exit 1; }

# Configurable package metadata (can be set via env vars by the user)
PKG_NAME="${PKG_NAME:-freebsd-app}"
PKG_VERSION="${PKG_VERSION:-1.0.0}"
PKG_ORIGIN="${PKG_ORIGIN:-local/${PKG_NAME}}"
PKG_PREFIX="${PKG_PREFIX:-/usr/local}"

# Detect maintainer from GitHub actor if not explicitly set
GITHUB_ACTOR="${GITHUB_ACTOR:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
if [ -n "$GITHUB_ACTOR" ] && [ -z "${MAINTAINER:-}" ]; then
    PKG_MAINTAINER="${GITHUB_ACTOR}@users.noreply.github.com"
else
    PKG_MAINTAINER="${MAINTAINER:-user@users.noreply.github.com}"
fi

# Detect project URL from GitHub repository if not explicitly set
if [ -n "$GITHUB_REPOSITORY" ] && [ -z "${PKG_WWW:-}" ]; then
    PKG_WWW="https://github.com/${GITHUB_REPOSITORY}"
else
    PKG_WWW="${PKG_WWW:-https://github.com/lggcs/freebsd-cross-compiler-action}"
fi

PKG_COMMENT="${PKG_COMMENT:-Cross-compiled FreeBSD application}"
PKG_DESC="${PKG_DESC:-Application cross-compiled by freebsd-cross-compiler-action}"
PKG_LICENSES="${PKG_LICENSES:-MIT}"

BINARY_DIR="${WORKSPACE}/${OUTPUT_DIR}"
PKG_OUTPUT="${BINARY_DIR}/${PKG_NAME}-${PKG_VERSION}.pkg"

echo "::group::[freebsd-cross] Packaging FreeBSD .pkg"
echo "Target ABI: ${PKG_ABI}"
echo "Prefix: ${PKG_PREFIX}"

# ── Find all ELF executables in the output directory ─────────────────
# Match ELF magic (7f 45 4c 46) and FreeBSD OS/ABI
BINARIES=()
for f in "$BINARY_DIR"/*; do
    [ -f "$f" ] || continue
    magic=$(head -c 4 "$f" 2>/dev/null | xxd -p 2>/dev/null || true)
    if [ "$magic" = "7f454c46" ]; then
        BINARIES+=("$f")
        debug_log "Found ELF binary: $f"
    fi
done

if [ "${#BINARIES[@]}" -eq 0 ]; then
    fail "No ELF binaries found in ${BINARY_DIR}. Build your project first."
fi

# ── Create staging directory ─────────────────────────────────────────
STAGING=$(mktemp -d /tmp/pkg-build.XXXXXX)
METADATA="${STAGING}/metadata"
STAGE_ROOT="${STAGING}/root"
mkdir -p "$METADATA" "$STAGE_ROOT/bin"

trap 'rm -rf "${STAGING}"' EXIT INT TERM

# ── Stage files (relative to prefix /usr/local) ─────────────────────
# FreeBSD convention: executables go in bin/ under the prefix
TOTAL_SIZE=0
for bin in "${BINARIES[@]}"; do
    name=$(basename "$bin")
    cp "$bin" "${STAGE_ROOT}/bin/${name}"
    chmod 0755 "${STAGE_ROOT}/bin/${name}"
    size=$(stat -c%s "$bin" 2>/dev/null || stat -f%z "$bin" 2>/dev/null || echo 0)
    TOTAL_SIZE=$((TOTAL_SIZE + size))
    debug_log "Staged: bin/${name} (${size} bytes)"
done

# ── Detect shared library dependencies from ELF binaries ─────────────
# Use readelf to extract NEEDED entries from the dynamic section
# These are the FreeBSD shared libraries the binary requires at runtime
SHLIBS_REQUIRED=()
for bin in "${BINARIES[@]}"; do
    if command -v readelf >/dev/null 2>&1; then
        # Extract DT_NEEDED entries
        while IFS= read -r lib; do
            [ -n "$lib" ] || continue
            # Deduplicate: only add if not already in the list
            already=0
            for existing in "${SHLIBS_REQUIRED[@]:-}"; do
                if [ "$existing" = "$lib" ]; then
                    already=1
                    break
                fi
            done
            if [ "$already" -eq 0 ]; then
                SHLIBS_REQUIRED+=("$lib")
                debug_log "Shared lib required: $lib"
            fi
        done < <(readelf -d "$bin" 2>/dev/null | grep 'NEEDED' | sed 's/.*\[\(.*\)\].*/\1/')
    fi
done

# ── Generate +MANIFEST in UCL format ────────────────────────────────
# UCL is a superset of JSON — valid JSON is valid UCL.
# We use JSON for correctness and machine-readability.
debug_log "Generating +MANIFEST (UCL/JSON format)"

MANIFEST="${METADATA}/+MANIFEST"

# Build files object: { "bin/name": "sha256=hash", ... }
FILES_JSON=""
for bin in "${BINARIES[@]}"; do
    name=$(basename "$bin")
    hash=$(sha256sum "$bin" | cut -d' ' -f1)
    entry="\"bin/${name}\": \"sha256=${hash}\""
    if [ -n "$FILES_JSON" ]; then
        FILES_JSON="${FILES_JSON},\n    ${entry}"
    else
        FILES_JSON="    ${entry}"
    fi
done

# Build shlibs.required JSON array
SHLIBS_JSON=""
for lib in "${SHLIBS_REQUIRED[@]:-}"; do
    if [ -n "$SHLIBS_JSON" ]; then
        SHLIBS_JSON="${SHLIBS_JSON}, \"${lib}\""
    else
        SHLIBS_JSON="\"${lib}\""
    fi
done

# Build dirs array (directories created by this package)
DIRS_JSON="\"bin\""

# Build licenses array from comma-separated input
LICENSES_JSON=""
IFS=',' read -ra LICENSE_ARRAY <<< "$PKG_LICENSES"
for lic in "${LICENSE_ARRAY[@]}"; do
    lic=$(echo "$lic" | xargs)  # trim whitespace
    if [ -n "$LICENSES_JSON" ]; then
        LICENSES_JSON="${LICENSES_JSON}, \"${lic}\""
    else
        LICENSES_JSON="\"${lic}\""
    fi
done

# Write the manifest as JSON (valid UCL)
cat > "$MANIFEST" <<EOF
{
  "name": "${PKG_NAME}",
  "version": "${PKG_VERSION}",
  "origin": "${PKG_ORIGIN}",
  "arch": "${PKG_ABI}",
  "prefix": "${PKG_PREFIX}",
  "comment": "${PKG_COMMENT}",
  "desc": "${PKG_DESC}",
  "maintainer": "${PKG_MAINTAINER}",
  "www": "${PKG_WWW}",
  "licenses": [${LICENSES_JSON}],
  "categories": ["local"],
  "files": {
$(echo -e "$FILES_JSON")
  },
  "dirs": [${DIRS_JSON}],
  "flatsize": ${TOTAL_SIZE},
  "shlibs": {
    "required": [${SHLIBS_JSON}],
    "provided": []
  }
}
EOF

debug_log "Manifest written:"
[ "$DEBUG" = "true" ] || [ "$DEBUG" = "True" ] && cat "$MANIFEST"

# ── Generate +MTREE_DIRS in mtree format ────────────────────────────
# FreeBSD pkg uses standard mtree specification format
MTREE="${METADATA}/+MTREE_DIRS"

cat > "$MTREE" <<'EOF'
# ./
.                        type=dir uname=root gname=wheel mode=0755
./bin                    type=dir uname=root gname=wheel mode=0755
EOF

debug_log "MTREE written:"
[ "$DEBUG" = "true" ] || [ "$DEBUG" = "True" ] && cat "$MTREE"

# ── Create the .pkg archive ─────────────────────────────────────────
# FreeBSD pkg-create default format is tzst (zstd-compressed tar).
# The .pkg extension is used regardless of compression.
# Archive order: +MANIFEST first, then +MTREE_DIRS, then payload files.
#
# We use zstd (matching modern pkg default). Fall back to xz if zstd unavailable.

debug_log "Creating ${PKG_OUTPUT}"
mkdir -p "$(dirname "$PKG_OUTPUT")"

COMPRESSION="zstd"
if ! command -v zstd >/dev/null 2>&1; then
    sudo apt-get install -y -qq zstd 2>/dev/null || true
fi
if ! command -v zstd >/dev/null 2>&1; then
    COMPRESSION="xz"
    echo "::warning::zstd not available, falling back to xz compression (modern FreeBSD default is tzst)"
fi

cd "$STAGE_ROOT"

if [ "$COMPRESSION" = "zstd" ]; then
    # Create tar.zst with +MANIFEST as first entry, then +MTREE_DIRS, then payload
    # The metadata files must be first in the archive (pkg expects this)
    tar --zstd -cf "$PKG_OUTPUT" \
        -C "$METADATA" "+MANIFEST" "+MTREE_DIRS" \
        -C "$STAGE_ROOT" .
else
    tar -cJf "$PKG_OUTPUT" \
        -C "$METADATA" "+MANIFEST" "+MTREE_DIRS" \
        -C "$STAGE_ROOT" .
fi

# ── Verify the package ───────────────────────────────────────────────
if [ -f "$PKG_OUTPUT" ]; then
    PKG_SIZE=$(ls -lh "$PKG_OUTPUT" | awk '{print $5}')
    PKG_HASH=$(sha256sum "$PKG_OUTPUT" | cut -d' ' -f1)
    echo "::notice::FreeBSD .pkg created: ${PKG_OUTPUT} (${PKG_SIZE})"
    echo "::notice::Package SHA-256: ${PKG_HASH}"
    echo "::notice::Compression: ${COMPRESSION}"
    debug_log "Binaries packaged: ${#BINARIES[@]}"
    SHLIBS_COUNT=${#SHLIBS_REQUIRED[@]}
    debug_log "Shared libs required: ${SHLIBS_COUNT}"
    debug_log "Total uncompressed size: ${TOTAL_SIZE} bytes"
else
    fail ".pkg creation failed"
fi

# ── Write audit metadata ────────────────────────────────────────────
AUDIT_FILE="${BINARY_DIR}/pkg-audit.json"
cat > "$AUDIT_FILE" <<EOF
{
  "package": "${PKG_NAME}-${PKG_VERSION}",
  "abi": "${PKG_ABI}",
  "origin": "${PKG_ORIGIN}",
  "prefix": "${PKG_PREFIX}",
  "compression": "${COMPRESSION}",
  "pkg_sha256": "${PKG_HASH}",
  "flatsize": ${TOTAL_SIZE},
  "binaries": [
$(for i in "${!BINARIES[@]}"; do
    bin="${BINARIES[$i]}"
    name=$(basename "$bin")
    hash=$(sha256sum "$bin" | cut -d' ' -f1)
    [ $i -gt 0 ] && echo ","
    printf '    {"name": "%s", "sha256": "%s"}' "$name" "$hash"
done)
  ],
  "shlibs_required": [$(echo "$SHLIBS_JSON" | sed 's/,/,\n/g' | sed 's/^/    /' | tr '\n' ' ' | sed 's/ *$//')]
}
EOF
debug_log "Audit metadata: ${AUDIT_FILE}"

# Set step output
echo "pkg-path=${PKG_OUTPUT}" >> "$GITHUB_OUTPUT"

echo "::endgroup::"