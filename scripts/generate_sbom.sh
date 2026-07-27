#!/usr/bin/env bash
# generate_sbom.sh — Generate SBOM in CycloneDX and/or SPDX format
#
# Scans the build output directory for ELF binaries targeting FreeBSD,
# extracts dependency information, and produces SBOM documents.
set -euo pipefail

SBOM_FORMAT="${INPUT_SBOM_FORMAT:-both}"
OUTPUT_DIR="${INPUT_OUTPUT_DIR:-build-freebsd}"
WORKSPACE="${WORKSPACE:-$(pwd)}"
DEBUG="${INPUT_DEBUG:-false}"

debug_log() { if [ "$DEBUG" = "true" ] || [ "$DEBUG" = "True" ]; then echo "[freebsd-cross] DEBUG: $*"; fi; }
fail() { echo "::error::$*"; exit 1; }

ACTION_PATH="${GITHUB_ACTION_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
SBOM_DIR="${WORKSPACE}/${OUTPUT_DIR}/sbom"
mkdir -p "$SBOM_DIR"

# ── Helper: resolve FreeBSD shared library versions ──────────────────
resolve_freebsd_libs() {
    local deps_file="$1"
    local resolved_file="$2"
    local sysroot="${FREEBSD_SYSROOT:-}"

    if [ -z "$sysroot" ] || [ ! -d "$sysroot" ]; then
        debug_log "Sysroot not available for lib resolution"
        cp "$deps_file" "$resolved_file"
        return
    fi

    # Build a map of libname -> version from sysroot
    local libmap
    libmap=$(mktemp)
    find "$sysroot/lib" -name '*.so*' -type f 2>/dev/null | while read -r libpath; do
        local libname
        libname=$(basename "$libpath")
        echo "${libname}=${libpath}"
    done | sort > "$libmap"

    # Resolve each dependency
    while IFS='|' read -r binary dep; do
        local resolved=""
        if [ -f "$sysroot/lib/$dep" ]; then
            resolved="$sysroot/lib/$dep"
        elif [ -f "$sysroot/usr/lib/$dep" ]; then
            resolved="$sysroot/usr/lib/$dep"
        else
            # Try basename match using libmap (handles versioned .so.N names)
            local basename
            basename=$(echo "$dep" | sed 's/\.so.*/.so/')
            resolved=$(grep "^${dep}=" "$libmap" 2>/dev/null | head -1 | cut -d= -f2 || true)
            if [ -z "$resolved" ]; then
                resolved=$(grep "^${basename}\." "$libmap" 2>/dev/null | head -1 | cut -d= -f2 || true)
            fi
        fi
        echo "${binary}|${dep}|${resolved}"
    done < "$deps_file" > "$resolved_file"

    rm -f "$libmap"
}

# ── Helper: extract dependency info from ELF binaries ───────────────
# Outputs lines of "binary_name|shared_lib_name" to deps_file
extract_elf_deps() {
    local target_dir="$1"
    local deps_file="$2"

    : > "$deps_file"

    # Find all ELF files in the output directory
    find "$target_dir" -type f 2>/dev/null | while read -r binary; do
        local magic
        magic=$(head -c 4 "$binary" 2>/dev/null | xxd -p 2>/dev/null || true)
        if [ "$magic" != "7f454c46" ]; then
            continue
        fi

        local name
        name=$(basename "$binary")

        # Extract NEEDED entries from dynamic section
        if command -v readelf >/dev/null 2>&1; then
            readelf -d "$binary" 2>/dev/null | grep 'NEEDED' | sed 's/.*\[\(.*\)\].*/\1/' | while read -r lib; do
                echo "${name}|${lib}" >> "$deps_file"
            done
        fi
    done
}

# ── Generate CycloneDX SBOM ──────────────────────────────────────────
generate_cyclonedx() {
    local output="$1"

    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000-0000-0000-0000-000000000000")
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local deps_file
    deps_file=$(mktemp)
    if [ -d "${WORKSPACE}/${OUTPUT_DIR}" ]; then
        extract_elf_deps "${WORKSPACE}/${OUTPUT_DIR}" "$deps_file"
    fi

    # Build unique lists of binaries and libraries
    local binaries_list libs_list
    binaries_list=$(mktemp)
    libs_list=$(mktemp)
    cut -d'|' -f1 "$deps_file" | sort -u > "$binaries_list"
    cut -d'|' -f2 "$deps_file" | sort -u > "$libs_list"

    # Build components array using a temp file
    local components_file
    components_file=$(mktemp)
    local comp_first=1

    while IFS= read -r binary; do
        [ -n "$binary" ] || continue
        [ "$comp_first" -eq 0 ] && echo "," >> "$components_file"
        comp_first=0
        {
            echo '    {'
            echo '      "type": "application",'
            echo "      \"name\": \"${binary}\","
            echo "      \"purl\": \"pkg:freebsd-binary/${binary}@${GITHUB_SHA:-latest}\""
            echo -n '    }'
        } >> "$components_file"
    done < "$binaries_list"

    while IFS= read -r lib; do
        [ -n "$lib" ] || continue
        [ "$comp_first" -eq 0 ] && echo "," >> "$components_file"
        comp_first=0
        {
            echo '    {'
            echo '      "type": "library",'
            echo "      \"name\": \"${lib}\","
            echo "      \"purl\": \"pkg:freebsd-lib/${lib}\""
            echo -n '    }'
        } >> "$components_file"
    done < "$libs_list"

    # Build dependencies array using a temp file
    local dependencies_file
    dependencies_file=$(mktemp)
    local dep_first=1

    while IFS= read -r binary; do
        [ -n "$binary" ] || continue
        [ "$dep_first" -eq 0 ] && echo "," >> "$dependencies_file"
        dep_first=0
        {
            echo '    {'
            echo "      \"ref\": \"pkg:freebsd-binary/${binary}@latest\","
            echo '      "dependsOn": ['
        } >> "$dependencies_file"

        local lib_first=1
        grep "^${binary}|" "$deps_file" | cut -d'|' -f2 | sort -u | while IFS= read -r dep; do
            [ -n "$dep" ] || continue
            [ "$lib_first" -eq 0 ] && echo "," >> "$dependencies_file"
            lib_first=0
            printf '        "pkg:freebsd-lib/%s"' "$dep" >> "$dependencies_file"
        done
        echo '' >> "$dependencies_file"
        echo '      ]' >> "$dependencies_file"
        echo -n '    }' >> "$dependencies_file"
    done < "$binaries_list"

    # Assemble final JSON
    {
        echo '{'
        echo '  "bomFormat": "CycloneDX",'
        echo '  "specVersion": "1.5",'
        echo "  \"serialNumber\": \"urn:uuid:${uuid}\","
        echo "  \"version\": 1,"
        echo "  \"metadata\": {"
        echo "    \"timestamp\": \"${timestamp}\","
        echo '    "tools": ['
        echo '      {'
        echo '        "vendor": "freebsd-cross-compiler-action",'
        echo '        "name": "freebsd-cross-compiler",'
        echo "        \"version\": \"1.0.0\""
        echo '      }'
        echo '    ],'
        echo '    "component": {'
        echo '      "type": "application",'
        echo "      \"name\": \"${GITHUB_REPOSITORY:-unknown}\","
        echo "      \"purl\": \"pkg:freebsd/${GITHUB_REPOSITORY:-unknown}@${GITHUB_SHA:-latest}\""
        echo '    }'
        echo '  },'
        echo '  "components": ['
        cat "$components_file"
        echo ''
        echo '  ],'
        echo '  "dependencies": ['
        cat "$dependencies_file"
        echo ''
        echo '  ]'
        echo '}'
    } > "$output"

    rm -f "$deps_file" "$binaries_list" "$libs_list" "$components_file" "$dependencies_file" 2>/dev/null || true
    debug_log "CycloneDX SBOM written to ${output}"
}

# ── Generate SPDX SBOM ───────────────────────────────────────────────
generate_spdx() {
    local output="$1"

    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local doc_uuid
    doc_uuid="spdx-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "00000000")"

    local deps_file
    deps_file=$(mktemp)
    if [ -d "${WORKSPACE}/${OUTPUT_DIR}" ]; then
        extract_elf_deps "${WORKSPACE}/${OUTPUT_DIR}" "$deps_file"
    fi

    # Build unique lists
    local binaries_seen libs_seen
    binaries_seen=$(mktemp)
    libs_seen=$(mktemp)
    while IFS='|' read -r binary dep; do
        [ -n "$binary" ] && echo "$binary" >> "$binaries_seen"
        [ -n "$dep" ] && echo "$dep" >> "$libs_seen"
    done < "$deps_file"

    {
        echo "SPDXVersion: SPDX-2.3"
        echo "DataLicense: CC0-1.0"
        echo "SPDXID: SPDXRef-DOCUMENT"
        echo "DocumentName: freebsd-cross-compile-sbom"
        echo "DocumentNamespace: https://github.com/lggcs/freebsd-cross-compiler-action/${doc_uuid}"
        echo "Creator: Tool: freebsd-cross-compiler-action v1.0.0"
        echo "Created: ${timestamp}"
        echo ""

        # Package sections: binaries
        local pkg_index=0
        sort -u "$binaries_seen" | while read -r binary; do
            [ -n "$binary" ] || continue
            pkg_index=$((pkg_index + 1))
            echo "PackageName: ${binary}"
            echo "SPDXID: SPDXRef-Package-${pkg_index}"
            echo "PackageDownloadLocation: NOASSERTION"
            echo "PackageLicenseConcluded: NOASSERTION"
            echo "PackageLicenseDeclared: NOASSERTION"
            echo "PackageCopyrightText: NOASSERTION"
            echo ""
        done

        # Package sections: shared library dependencies
        local dep_index=0
        sort -u "$libs_seen" | while read -r lib; do
            [ -n "$lib" ] || continue
            dep_index=$((dep_index + 1))
            echo "PackageName: ${lib}"
            echo "SPDXID: SPDXRef-Dependency-${lib}"
            echo "PackageDownloadLocation: NOASSERTION"
            echo "PackageLicenseConcluded: NOASSERTION"
            echo "PackageLicenseDeclared: NOASSERTION"
            echo "PackageCopyrightText: NOASSERTION"
            echo ""
        done

        # Relationships: binary DEPENDS_ON lib
        local rel_index=0
        sort -u "$binaries_seen" | while read -r binary; do
            [ -n "$binary" ] || continue
            rel_index=$((rel_index + 1))
            local pkg_id="SPDXRef-Package-${rel_index}"
            grep "^${binary}|" "$deps_file" | cut -d'|' -f2 | sort -u | while read -r dep; do
                [ -n "$dep" ] || continue
                echo "Relationship: ${pkg_id} DEPENDS_ON SPDXRef-Dependency-${dep}"
            done
        done

    } > "$output"

    rm -f "$deps_file" "$binaries_seen" "$libs_seen" 2>/dev/null || true
    debug_log "SPDX SBOM written to ${output}"
}

# ── Main ─────────────────────────────────────────────────────────────
echo "::group::[freebsd-cross] SBOM generation"
echo "Generating SBOM (format: ${SBOM_FORMAT}) for ${OUTPUT_DIR}..."

CYCLONEDX_OUT=""
SPDX_OUT=""

case "$SBOM_FORMAT" in
    cyclonedx)
        CYCLONEDX_OUT="${SBOM_DIR}/sbom.cyclonedx.json"
        generate_cyclonedx "$CYCLONEDX_OUT"
        ;;
    spdx)
        SPDX_OUT="${SBOM_DIR}/sbom.spdx"
        generate_spdx "$SPDX_OUT"
        ;;
    both)
        CYCLONEDX_OUT="${SBOM_DIR}/sbom.cyclonedx.json"
        generate_cyclonedx "$CYCLONEDX_OUT"
        SPDX_OUT="${SBOM_DIR}/sbom.spdx"
        generate_spdx "$SPDX_OUT"
        ;;
    *)
        fail "Unknown SBOM format: ${SBOM_FORMAT}. Use: cyclonedx, spdx, or both"
        ;;
esac

echo ""

# Set step outputs
if [ -n "$CYCLONEDX_OUT" ]; then
    echo "cyclonedx=${CYCLONEDX_OUT}" >> "$GITHUB_OUTPUT"
    echo "::notice::CycloneDX SBOM: ${CYCLONEDX_OUT}"
fi
if [ -n "$SPDX_OUT" ]; then
    echo "spdx=${SPDX_OUT}" >> "$GITHUB_OUTPUT"
    echo "::notice::SPDX SBOM: ${SPDX_OUT}"
fi

echo "::endgroup::"