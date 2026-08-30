#!/bin/bash
# verify-bundle.sh — Verify a Parallax .app bundle's structure, signature,
# and content manifest integrity. Standalone checker; also called by
# build-release.sh internally.
#
# Usage:
#   ./Scripts/verify-bundle.sh path/to/Parallax.app
#   ./Scripts/verify-bundle.sh path/to/Parallax.app --quiet

set -euo pipefail

APP_BUNDLE="${1:-}"
QUIET=false
if [[ "${2:-}" == "--quiet" ]]; then
    QUIET=true
fi

if [[ -z "$APP_BUNDLE" ]]; then
    echo "Usage: $0 <path-to-app-bundle> [--quiet]" >&2
    exit 1
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "ERROR: bundle not found: $APP_BUNDLE" >&2
    exit 1
fi

errors=0
log() { if [[ "$QUIET" != true ]]; then echo "$@"; fi }

# ---------------------------------------------------------------------------
# 1. Required bundle structure
# ---------------------------------------------------------------------------
log "=== Structure check: $APP_BUNDLE ==="
for required in \
    "Contents/MacOS/ParallaxApp" \
    "Contents/Info.plist" \
    "Contents/Resources/content-manifest.txt"; do
    if [[ ! -f "$APP_BUNDLE/$required" ]]; then
        echo "FAIL: missing required file: $required" >&2
        errors=$((errors + 1))
    else
        log "  OK: $required"
    fi
done

# Executable must be runnable.
if [[ -f "$APP_BUNDLE/Contents/MacOS/ParallaxApp" ]]; then
    if [[ ! -x "$APP_BUNDLE/Contents/MacOS/ParallaxApp" ]]; then
        echo "FAIL: executable is not runnable" >&2
        errors=$((errors + 1))
    else
        log "  OK: executable is runnable"
    fi
fi

# Info.plist must have version stamps.
if [[ -f "$APP_BUNDLE/Contents/Info.plist" ]]; then
    ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || echo '')"
    if [[ -z "$ver" ]]; then
        echo "FAIL: CFBundleShortVersionString missing" >&2
        errors=$((errors + 1))
    else
        log "  OK: version $ver"
    fi
fi

# ---------------------------------------------------------------------------
# 2. Code signature
# ---------------------------------------------------------------------------
log "=== Code signature check ==="
if codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" >/dev/null 2>&1; then
    log "  OK: signature valid"
else
    echo "FAIL: codesign verification failed" >&2
    errors=$((errors + 1))
fi

# ---------------------------------------------------------------------------
# 3. Content manifest integrity
# ---------------------------------------------------------------------------
MANIFEST="$APP_BUNDLE/Contents/Resources/content-manifest.txt"
if [[ ! -f "$MANIFEST" ]]; then
    echo "FAIL: content manifest not found" >&2
    errors=$((errors + 1))
else
    log "=== Manifest integrity check ==="
    file_count=0
    hash_errors=0
    # Bash 3.2-safe while-read loop.
    while IFS= read -r line; do
        # Skip comments and blank lines.
        case "$line" in ''|'#'*) continue ;; esac
        expected_sha="$(echo "$line" | awk '{print $1}')"
        rel_path="$(echo "$line" | awk '{print $3}')"
        if [[ -z "$rel_path" || "$rel_path" == "Contents/Resources/content-manifest.txt" ]]; then
            continue
        fi
        # Skip the main executable — code signing embeds the signature
        # into the Mach-O binary, changing its hash after the manifest was
        # generated. The executable's integrity is verified by the code
        # signature check above.
        if [[ "$rel_path" == "Contents/MacOS/ParallaxApp" ]]; then
            continue
        fi
        file_count=$((file_count + 1))
        full_path="$APP_BUNDLE/$rel_path"
        if [[ ! -f "$full_path" ]]; then
            echo "FAIL: missing file from manifest: $rel_path" >&2
            hash_errors=$((hash_errors + 1))
            continue
        fi
        actual_sha="$(shasum -a 256 "$full_path" | awk '{print $1}')"
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            echo "FAIL: hash mismatch: $rel_path" >&2
            echo "       expected: $expected_sha" >&2
            echo "       actual:   $actual_sha" >&2
            hash_errors=$((hash_errors + 1))
        fi
    done < "$MANIFEST"
    log "  Files checked: $file_count"
    log "  Hash errors: $hash_errors"
    if [[ "$hash_errors" -gt 0 ]]; then
        errors=$((errors + hash_errors))
    else
        log "  OK: all manifest hashes match"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [[ "$errors" -gt 0 ]]; then
    echo "RESULT: FAIL ($errors error(s))" >&2
    exit 1
else
    log "RESULT: PASS — bundle verified"
    exit 0
fi
