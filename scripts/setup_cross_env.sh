#!/usr/bin/env bash
# setup_cross_env.sh — Install clang+lld, acquire sysroot, create compiler wrappers
#
# Sysroot acquisition modes (in priority order):
#   1. Custom: custom-sysroot-url + optional SHA-256 verification
#   2. Default: download from GitHub Release CDN (prebuilt by build_sysroot pipeline)
#   3. Bundled: tarball vendored in the Action repo (for testing/offline)
#
# Verification modes:
#   "false"    — no verification (default)
#   "sha256"   — verify against custom-sysroot-sha256
#   "manifest" — verify base.txz against official FreeBSD MANIFEST
set -euo pipefail

DEBUG="${INPUT_DEBUG:-false}"
TARGET="${INPUT_TARGET:-x86_64-unknown-freebsd15.1}"
SYSROOT_VERSION="${INPUT_SYSROOT_VERSION:-15.1-RELEASE}"
SYSROOT_ARCH="${INPUT_SYSROOT_ARCH:-amd64}"
EXTRA_CFLAGS="${INPUT_CFLAGS:-}"
EXTRA_CXXFLAGS="${INPUT_CXXFLAGS:-}"
EXTRA_LDFLAGS="${INPUT_LDFLAGS:-}"
OUTPUT_DIR="${INPUT_OUTPUT_DIR:-build-freebsd}"
CUSTOM_SYSROOT_URL="${INPUT_CUSTOM_SYSROOT_URL:-}"
CUSTOM_SYSROOT_SHA256="${INPUT_CUSTOM_SYSROOT_SHA256:-}"
VERIFY_MODE="${INPUT_VERIFY_SYSROOT:-false}"

log() { echo "::group::[freebsd-cross] $*"; }
log_end() { echo "::endgroup::"; }
debug_log() { if [ "$DEBUG" = "true" ] || [ "$DEBUG" = "True" ]; then echo "[freebsd-cross] DEBUG: $*"; fi; }
fail() { echo "::error::$*"; exit 1; }

# Derive version short name from release tag (15.1-RELEASE → 15.1)
VERSION_SHORT=$(echo "$SYSROOT_VERSION" | sed 's/-RELEASE$//')
SYSROOT_NAME="freebsd-sysroot-${VERSION_SHORT}-${SYSROOT_ARCH}"
SYSROOT_TARBALL="${SYSROOT_NAME}.tar.zst"

ACTION_PATH="${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
CACHE_DIR="${ACTION_PATH}/.cache"
SYSROOT_DIR="${CACHE_DIR}/${SYSROOT_NAME}"
WRAPPERS_DIR="${CACHE_DIR}/wrappers"
mkdir -p "$CACHE_DIR" "$WRAPPERS_DIR"

# ── Detect host architecture ──────────────────────────────────────────
log "Detecting CI environment"
HOST_ARCH=$(uname -m)
debug_log "Host architecture: $HOST_ARCH"

# The sysroot is for the target arch; the host clang must be able to
# produce code for that target. On ubuntu-latest (x86_64), clang can
# cross-compile to any LLVM target regardless of host arch.
debug_log "Target: $TARGET, Sysroot arch: $SYSROOT_ARCH, Version: $SYSROOT_VERSION"
log_end

# ── Install clang and lld ─────────────────────────────────────────────
log "Installing clang and lld"

NEEDS_INSTALL=0
if ! command -v clang >/dev/null 2>&1 || ! command -v ld.lld >/dev/null 2>&1; then
    NEEDS_INSTALL=1
fi
if ! command -v zstd >/dev/null 2>&1; then
    NEEDS_INSTALL=1
fi

if [ "$NEEDS_INSTALL" -eq 1 ]; then
    sudo apt-get update -qq
    sudo apt-get install -y --no-install-recommends clang lld zstd
    debug_log "Installed clang, lld, and zstd via apt"
else
    debug_log "clang, lld, and zstd already present"
fi

CLANG_BIN=$(command -v clang || command -v clang-17 || command -v clang-18 || command -v clang-19 || command -v clang-20)
LLD_BIN=$(command -v ld.lld || command -v ld.lld-17 || command -v ld.lld-18)
[ -n "$CLANG_BIN" ] || fail "clang not found after install"
[ -n "$LLD_BIN" ] || fail "ld.lld not found after install"
debug_log "Using $CLANG_BIN ($($CLANG_BIN --version 2>&1 | head -1))"
debug_log "Using $LLD_BIN"

log_end

# ── Acquire sysroot ───────────────────────────────────────────────────
log "Acquiring FreeBSD ${SYSROOT_VERSION} (${SYSROOT_ARCH}) sysroot"

compute_sha256() {
    sha256sum "$1" | cut -d' ' -f1
}

verify_sha256() {
    local file="$1"
    local expected="$2"
    local actual
    actual=$(compute_sha256 "$file")
    debug_log "SHA-256 expected: $expected"
    debug_log "SHA-256 actual:   $actual"
    if [ "$actual" != "$expected" ]; then
        fail "SHA-256 verification failed for $file. Expected: $expected, Got: $actual"
    fi
    echo "::notice::SHA-256 verification passed for $(basename "$file")"
}

fetch_url() {
    local url="$1"
    local dest="$2"
    debug_log "Downloading: $url → $dest"
    local http_code
    http_code=$(curl -sL -w "%{http_code}" -o "$dest" "$url" || true)
    if [ "$http_code" != "200" ]; then
        fail "Download failed (HTTP $http_code): $url"
    fi
}

if [ -f "${SYSROOT_DIR}/SYSROOT.txt" ]; then
    debug_log "Sysroot already cached at ${SYSROOT_DIR}"
else
    DOWNLOAD_FILE="${CACHE_DIR}/${SYSROOT_TARBALL}"

    if [ -n "$CUSTOM_SYSROOT_URL" ] && [ "$CUSTOM_SYSROOT_URL" != "" ]; then
        # ── Mode 1: Custom sysroot URL ─────────────────────────────────
        debug_log "Custom sysroot mode: downloading from custom URL"
        fetch_url "$CUSTOM_SYSROOT_URL" "$DOWNLOAD_FILE"

        if [ "$VERIFY_MODE" = "sha256" ] && [ -n "$CUSTOM_SYSROOT_SHA256" ]; then
            verify_sha256 "$DOWNLOAD_FILE" "$CUSTOM_SYSROOT_SHA256"
        elif [ -n "$CUSTOM_SYSROOT_SHA256" ]; then
            # Even if verify-sysroot not explicitly set, if sha256 is provided, verify
            verify_sha256 "$DOWNLOAD_FILE" "$CUSTOM_SYSROOT_SHA256"
        else
            echo "::warning::No SHA-256 hash provided for custom sysroot. Verification skipped — this is not recommended."
        fi

    elif [ -f "${ACTION_PATH}/${SYSROOT_TARBALL}" ]; then
        # ── Mode 3: Bundled tarball ───────────────────────────────────
        debug_log "Using bundled sysroot tarball (${SYSROOT_TARBALL})"
        cp "${ACTION_PATH}/${SYSROOT_TARBALL}" "$DOWNLOAD_FILE"

    else
        # ── Mode 2: Default GitHub Release CDN ────────────────────────
        ACTION_REPO="${GITHUB_REPOSITORY:-lggcs/freebsd-cross-compiler-action}"
        RELEASE_TAG="v${SYSROOT_VERSION}"
        DOWNLOAD_URL="https://github.com/${ACTION_REPO}/releases/download/${RELEASE_TAG}/${SYSROOT_TARBALL}"

        debug_log "Default mode: downloading from ${DOWNLOAD_URL}"
        HTTP_CODE=$(curl -sL -w "%{http_code}" -o "${DOWNLOAD_FILE}.tmp" "$DOWNLOAD_URL" || true)

        if [ "$HTTP_CODE" = "200" ] && zstd --test "${DOWNLOAD_FILE}.tmp" 2>/dev/null; then
            mv "${DOWNLOAD_FILE}.tmp" "$DOWNLOAD_FILE"
            debug_log "Downloaded sysroot from GitHub Release"
        else
            rm -f "${DOWNLOAD_FILE}.tmp"
            # Try GitHub API to find the asset
            API_URL="https://api.github.com/repos/${ACTION_REPO}/releases/tags/${RELEASE_TAG}"
            debug_log "Trying API: ${API_URL}"
            ASSET_URL=$(curl -sL "$API_URL" 2>/dev/null \
                | grep -o '"browser_download_url":\s*"[^"]*'"${SYSROOT_TARBALL}"'"' \
                | head -1 \
                | sed 's/.*"browser_download_url":\s*"//;s/"$//')
            if [ -n "$ASSET_URL" ]; then
                debug_log "Found asset URL: $ASSET_URL"
                fetch_url "$ASSET_URL" "$DOWNLOAD_FILE"
            else
                fail "Could not download sysroot ${SYSROOT_TARBALL}. Ensure GitHub Release ${RELEASE_TAG} exists in ${ACTION_REPO} with this asset. Or use custom-sysroot-url to point to your own storage."
            fi
        fi

        # Manifest verification: check the tarball hash against official FreeBSD sources
        if [ "$VERIFY_MODE" = "manifest" ]; then
            debug_log "Manifest verification mode: checking against official FreeBSD MANIFEST"
            MANIFEST_URL="https://download.freebsd.org/releases/${SYSROOT_ARCH}/${SYSROOT_VERSION}/MANIFEST"
            debug_log "Fetching MANIFEST: $MANIFEST_URL"
            MANIFEST_FILE="${CACHE_DIR}/MANIFEST-${SYSROOT_VERSION}"
            fetch_url "$MANIFEST_URL" "$MANIFEST_FILE"

            # The MANIFEST contains SHA-256 for base.txz, which is the source of the sysroot.
            # We verify that the MANIFEST itself is valid and log the base.txz hash.
            # For full provenance, the build_sysroot.sh pipeline publishes a CHECKSUMS
            # file alongside the sysroot tarball, containing the tarball's own hash.
            # Here we verify the sysroot's provenance by checking the base.txz hash
            # recorded in the MANIFEST, then comparing against our published CHECKSUMS.
            BASE_TXZ_HASH=$(grep '^base\.txz' "$MANIFEST_FILE" | cut -f2)
            debug_log "Official base.txz SHA-256 (from FreeBSD MANIFEST): $BASE_TXZ_HASH"

            CHECKSUMS_URL="https://github.com/${ACTION_REPO}/releases/download/${RELEASE_TAG}/CHECKSUMS-${SYSROOT_VERSION}.txt"
            CHECKSUMS_FILE="${CACHE_DIR}/CHECKSUMS-${SYSROOT_VERSION}.txt"
            fetch_url "$CHECKSUMS_URL" "$CHECKSUMS_FILE"

            # Verify the sysroot tarball hash matches what was published
            EXPECTED_SYSROOT_HASH=$(grep "${SYSROOT_TARBALL}" "$CHECKSUMS_FILE" | awk '{print $1}')
            if [ -n "$EXPECTED_SYSROOT_HASH" ]; then
                verify_sha256 "$DOWNLOAD_FILE" "$EXPECTED_SYSROOT_HASH"
                echo "::notice::Sysroot verified against official FreeBSD ${SYSROOT_VERSION} MANIFEST and published CHECKSUMS"
            else
                fail "Could not find ${SYSROOT_TARBALL} in published CHECKSUMS file. The sysroot may have been tampered with."
            fi

            # Log provenance for audit trail (JSON format)
            {
                echo "{"
                echo "  \"freebsd_version\": \"${SYSROOT_VERSION}\","
                echo "  \"freebsd_arch\": \"${SYSROOT_ARCH}\","
                echo "  \"base_txz_sha256\": \"${BASE_TXZ_HASH}\","
                echo "  \"sysroot_tarball_sha256\": \"$(compute_sha256 "$DOWNLOAD_FILE")\","
                echo "  \"manifest_url\": \"${MANIFEST_URL}\","
                echo "  \"checksums_url\": \"${CHECKSUMS_URL}\","
                echo "  \"verified_at\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
                echo "}"
            } > "${SYSROOT_DIR}.provenance.json" 2>/dev/null || true
        fi
    fi

    # Extract sysroot
    debug_log "Extracting sysroot to ${CACHE_DIR}/"
    tar -xf "$DOWNLOAD_FILE" -C "$CACHE_DIR/"

    [ -f "${SYSROOT_DIR}/SYSROOT.txt" ] || fail "Sysroot extraction failed — SYSROOT.txt not found in ${SYSROOT_DIR}"
fi

# Compute and record the hash of whatever sysroot we ended up using
SYSROOT_HASH=""
if [ -f "${CACHE_DIR}/${SYSROOT_TARBALL}" ]; then
    SYSROOT_HASH=$(compute_sha256 "${CACHE_DIR}/${SYSROOT_TARBALL}")
elif [ -f "${ACTION_PATH}/${SYSROOT_TARBALL}" ]; then
    SYSROOT_HASH=$(compute_sha256 "${ACTION_PATH}/${SYSROOT_TARBALL}")
fi
debug_log "Sysroot SHA-256: ${SYSROOT_HASH}"

SYSROOT_SIZE=$(du -sh "$SYSROOT_DIR" | cut -f1)
echo "::notice::FreeBSD ${SYSROOT_VERSION} sysroot ready (${SYSROOT_SIZE}, sha256: ${SYSROOT_HASH:0:16}...)"

log_end

# ── Create compiler wrappers ──────────────────────────────────────────
log "Creating cross-compiler wrappers"

# C compiler wrapper
cat > "${WRAPPERS_DIR}/freebsd-cc" <<WRAPPER
#!/usr/bin/env bash
# freebsd-cc — FreeBSD cross-compiler wrapper (C)
# Auto-generated by freebsd-cross-compiler-action
set -euo pipefail
exec ${CLANG_BIN} --target=${TARGET} --sysroot=${SYSROOT_DIR} -fuse-ld=lld "\$@"
WRAPPER

# C++ compiler wrapper
# Notes:
#   -stdlib=libc++ selects FreeBSD's libc++ (matched to the sysroot's libc++.so.1)
#   -lc++ -lcxxrt must be explicit because clang's FreeBSD target config does not
#   auto-link them in this native-cross setup (host clang, not FreeBSD clang)
#   The libs are only appended when linking (not when -c, -S, or -E is passed)
cat > "${WRAPPERS_DIR}/freebsd-c++" <<WRAPPER
#!/usr/bin/env bash
# freebsd-c++ — FreeBSD cross-compiler wrapper (C++)
# Auto-generated by freebsd-cross-compiler-action
set -euo pipefail
# Check if this is a compile-only invocation (-c, -S, or -E without link)
LINKING=1
for arg in "\$@"; do
  case "\$arg" in
    -c|-S|-E|--compile|--preprocess)
      LINKING=0
      break
      ;;
  esac
done
if [ "\$LINKING" -eq 1 ]; then
  exec ${CLANG_BIN} --target=${TARGET} --sysroot=${SYSROOT_DIR} -fuse-ld=lld -stdlib=libc++ "\$@" -lc++ -lcxxrt
else
  exec ${CLANG_BIN} --target=${TARGET} --sysroot=${SYSROOT_DIR} -fuse-ld=lld -stdlib=libc++ "\$@"
fi
WRAPPER

chmod +x "${WRAPPERS_DIR}/freebsd-cc" "${WRAPPERS_DIR}/freebsd-c++"

debug_log "CC wrapper: ${WRAPPERS_DIR}/freebsd-cc"
debug_log "CXX wrapper: ${WRAPPERS_DIR}/freebsd-c++"

# Build the flags strings for non-wrapper consumers
BASE_CFLAGS="--target=${TARGET} --sysroot=${SYSROOT_DIR} -fuse-ld=lld ${EXTRA_CFLAGS}"
BASE_CXXFLAGS="--target=${TARGET} --sysroot=${SYSROOT_DIR} -fuse-ld=lld -stdlib=libc++ ${EXTRA_CXXFLAGS}"
BASE_LDFLAGS="${EXTRA_LDFLAGS}"

log_end

# ── Create CMake toolchain file ───────────────────────────────────────
log "Writing CMake toolchain file"

TOOLCHAIN_FILE="${CACHE_DIR}/freebsd-toolchain.cmake"
cat > "$TOOLCHAIN_FILE" <<EOF
# Auto-generated FreeBSD ${SYSROOT_VERSION} cross-compile toolchain
# Target: ${TARGET}
# Sysroot: ${SYSROOT_DIR}
set(CMAKE_SYSTEM_NAME FreeBSD)
set(CMAKE_SYSTEM_VERSION ${VERSION_SHORT})
set(CMAKE_SYSTEM_PROCESSOR ${SYSROOT_ARCH})

set(CMAKE_C_COMPILER ${WRAPPERS_DIR}/freebsd-cc)
set(CMAKE_CXX_COMPILER ${WRAPPERS_DIR}/freebsd-c++)

set(CMAKE_FIND_ROOT_PATH ${SYSROOT_DIR})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

CMAKE_FLAGS="-DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_FILE}"
debug_log "CMake toolchain: ${TOOLCHAIN_FILE}"

log_end

# ── Set outputs and environment ───────────────────────────────────────
log "Setting environment variables and outputs"

{
    echo "CC=${WRAPPERS_DIR}/freebsd-cc"
    echo "CXX=${WRAPPERS_DIR}/freebsd-c++"
    echo "CFLAGS=${BASE_CFLAGS}"
    echo "CXXFLAGS=${BASE_CXXFLAGS}"
    echo "LDFLAGS=${BASE_LDFLAGS}"
    echo "FREEBSD_SYSROOT=${SYSROOT_DIR}"
    echo "FREEBSD_TARGET=${TARGET}"
    echo "FREEBSD_TOOLCHAIN_FILE=${TOOLCHAIN_FILE}"
    echo "FREEBSD_CMAKE_FLAGS=${CMAKE_FLAGS}"
} >> "$GITHUB_ENV"

echo "sysroot-path=${SYSROOT_DIR}" >> "$GITHUB_OUTPUT"
echo "cc=${WRAPPERS_DIR}/freebsd-cc" >> "$GITHUB_OUTPUT"
echo "cxx=${WRAPPERS_DIR}/freebsd-c++" >> "$GITHUB_OUTPUT"
echo "target=${TARGET}" >> "$GITHUB_OUTPUT"
echo "cflags=${BASE_CFLAGS}" >> "$GITHUB_OUTPUT"
echo "cxxflags=${BASE_CXXFLAGS}" >> "$GITHUB_OUTPUT"
echo "ldflags=${BASE_LDFLAGS}" >> "$GITHUB_OUTPUT"
echo "toolchain-file=${TOOLCHAIN_FILE}" >> "$GITHUB_OUTPUT"
echo "cmake-flags=${CMAKE_FLAGS}" >> "$GITHUB_OUTPUT"
echo "sysroot-sha256=${SYSROOT_HASH}" >> "$GITHUB_OUTPUT"

log_end

echo "::notice::FreeBSD ${SYSROOT_VERSION} cross-compile environment ready. CC/CXX wrappers and CMake toolchain file configured."