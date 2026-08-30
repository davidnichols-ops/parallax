#!/bin/bash
# build-release.sh — Build a macOS .app bundle and drag-to-Applications DMG.
#
# Robust Bash 3.2 (macOS system shell) packaging with:
#   - Validated --version (semver-like) and --output path arguments
#   - Recoverable previous outputs (timestamped backup, never blind rm -rf)
#   - .app bundle resource copies (docs, rulebook, icon, content manifest)
#   - Original geometric app icon generation (Scripts/generate-icon.swift)
#   - Content manifest with SHA-256 hashes and byte sizes
#   - Bundle verification (structure, codesign, manifest integrity)
#
# Usage:
#   ./Scripts/build-release.sh
#   ./Scripts/build-release.sh --version 1.2.0 --output ./dist
#   ./Scripts/build-release.sh --sign "Developer ID Application: …" \
#       --notarize --notary-profile "notary-profile"
#
# The default is an ad-hoc-signed developer build. Public distribution requires
# a Developer ID signature and Apple notarization.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Parallax"
BUNDLE_ID="com.parallax.app"
VERSION="2.0.0"
OUTPUT_DIR="$PROJECT_DIR/dist"
SIGN_IDENTITY=""
NOTARIZE=false
NOTARY_PROFILE=""
SKIP_ICON=false
SKIP_BUILD=false
SCRATCH_PATH=""

# ---------------------------------------------------------------------------
# Bash 3.2-safe helpers
# ---------------------------------------------------------------------------

# Validate a semver-like version string: MAJOR.MINOR.PATCH with optional
# pre-release suffix. Rejects empty, non-numeric components, and shell
# metacharacters.
validate_version() {
    local ver="$1"
    if [[ -z "$ver" ]]; then
        echo "ERROR: version is empty." >&2
        return 1
    fi
    # Allow digits, dots, hyphens, alphanumerics only. No spaces, no slashes,
    # no shell-special chars.
    if [[ ! "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9]+)*$ ]]; then
        echo "ERROR: invalid version '$ver'. Expected MAJOR.MINOR.PATCH (e.g. 1.0.0)." >&2
        return 1
    fi
    return 0
}

# Validate an output directory path: must be absolute or relative-but-safe,
# must not be /, must not contain .., must not be a broad/home/project-root
# path (to avoid accidental clobbering), and its parent must be writable or
# creatable.
validate_output_path() {
    local path="$1"
    if [[ -z "$path" ]]; then
        echo "ERROR: output path is empty." >&2
        return 1
    fi
    # Reject root and traversal patterns.
    if [[ "$path" == "/" || "$path" == ".." || "$path" == */.. || "$path" == /*/../* || "$path" == *../* || "$path" == ../* ]]; then
        echo "ERROR: unsafe output path '$path' (root or traversal)." >&2
        return 1
    fi
    # Resolve to absolute.
    local abs
    if [[ "$path" == /* ]]; then
        abs="$path"
    else
        abs="$PROJECT_DIR/$path"
    fi
    # Normalize trailing slash for comparison.
    abs="${abs%/}"
    # Canonicalize existing directories, including symlinks and '/.'.
    if [[ -d "$abs" ]]; then
        abs="$(cd "$abs" && pwd -P)"
    fi
    # Block broad/home/project-root paths — the output must be a dedicated
    # subdirectory, not a place where other data lives. We do NOT delete the
    # output dir (we back it up), but writing a .app there should still be
    # scoped to avoid surprises.
    local home_norm="${HOME%/}"
    local project_norm="${PROJECT_DIR%/}"
    if [[ "$abs" == "$home_norm" || "$abs" == "$project_norm" \
          || "$abs" == "/Users" || "$abs" == "/Users/david" \
          || "$abs" == "/" || "$abs" == "/tmp" || "$abs" == "/var" \
          || "$abs" == "/private/tmp" ]]; then
        echo "ERROR: refusing to use broad path '$abs' as output." >&2
        echo "       Specify a dedicated subdirectory (e.g. ./dist or /tmp/parallax-out)." >&2
        return 1
    fi
    # Check parent directory exists or can be created.
    local parent
    parent="$(dirname "$abs")"
    if [[ ! -d "$parent" ]]; then
        if ! mkdir -p "$parent" 2>/dev/null; then
            echo "ERROR: cannot create output parent directory '$parent'." >&2
            return 1
        fi
    fi
    if [[ ! -w "$parent" ]]; then
        echo "ERROR: output parent '$parent' is not writable." >&2
        return 1
    fi
    OUTPUT_DIR="$abs"
    return 0
}

# Validate a scratch path for SPM --scratch-path: must be absolute, must not
# be root/home/project/broad, must not contain .., parent must be creatable.
validate_scratch_path() {
    local path="$1"
    if [[ -z "$path" ]]; then
        echo "ERROR: scratch path is empty." >&2
        return 1
    fi
    if [[ "$path" != /* ]]; then
        echo "ERROR: scratch path must be absolute: '$path'." >&2
        return 1
    fi
    if [[ "$path" == *..* || "$path" == "/" ]]; then
        echo "ERROR: unsafe scratch path '$path'." >&2
        return 1
    fi
    local path_norm="${path%/}"
    local home_norm="${HOME%/}"
    local project_norm="${PROJECT_DIR%/}"
    if [[ "$path_norm" == "$home_norm" || "$path_norm" == "$project_norm" \
          || "$path_norm" == "/Users" || "$path_norm" == "/Users/david" \
          || "$path_norm" == "/tmp" || "$path_norm" == "/private/tmp" ]]; then
        echo "ERROR: refusing to use broad path '$path_norm' as scratch." >&2
        return 1
    fi
    # Parent must exist or be creatable.
    local parent
    parent="$(dirname "$path_norm")"
    if [[ ! -d "$parent" ]]; then
        if ! mkdir -p "$parent" 2>/dev/null; then
            echo "ERROR: cannot create scratch parent '$parent'." >&2
            return 1
        fi
    fi
    return 0
}

# SHA-256 of a file (shasum is always present on macOS).
file_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

# Human-readable byte size.
file_size() {
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo "0"
}

# Timestamped backup of a path (file or directory). Moves it to
# <path>.backup-YYYYMMDD-HHMMSS. Returns 0 if nothing to back up.
recoverable_backup() {
    local target="$1"
    LAST_BACKUP=""
    if [[ -e "$target" ]]; then
        local stamp
        stamp="$(date +%Y%m%d-%H%M%S)"
        local backup="${target}.backup-${stamp}"
        local suffix=0
        while [[ -e "$backup" ]]; do
            suffix=$((suffix + 1))
            backup="${target}.backup-${stamp}-${suffix}"
        done
        mv "$target" "$backup"
        LAST_BACKUP="$backup"
        echo "  Recovered previous output to: $backup"
    fi
}

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --output PATH          Output directory (default: ./dist)
  --version VERSION      Version string MAJOR.MINOR.PATCH (default: 2.0.0)
  --sign IDENTITY        Developer ID Application identity for signing
  --notarize             Submit DMG for Apple notarization (requires --sign)
  --notary-profile NAME  notarytool keychain profile (required with --notarize)
  --scratch-path PATH    Unique SPM scratch path for concurrent builds
  --skip-icon            Skip icon generation (use existing Scripts/AppIcon.icns)
  --skip-build           Skip swift build (use existing binary; for testing)
  --help, -h             Show this help
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
# Helper: check that an option has a following argument. Under `set -u`,
# expanding `$2` when absent crashes. This checks `$#` (remaining arg count)
# rather than the value, so an explicit empty-string argument (e.g.
# `--version ""`) passes through to validation instead of being treated as
# missing.
require_arg() {
    local opt="$1" remaining="$2"
    if [[ "$remaining" -lt 1 ]]; then
        echo "ERROR: $opt requires an argument." >&2
        usage
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            require_arg "$1" $(($# - 1))
            OUTPUT_DIR_ARG="$2"; shift 2 ;;
        --version)
            require_arg "$1" $(($# - 1))
            VERSION="$2"; shift 2 ;;
        --sign)
            require_arg "$1" $(($# - 1))
            SIGN_IDENTITY="$2"; shift 2 ;;
        --notarize)       NOTARIZE=true; shift ;;
        --notary-profile)
            require_arg "$1" $(($# - 1))
            NOTARY_PROFILE="$2"; shift 2 ;;
        --scratch-path)
            require_arg "$1" $(($# - 1))
            SCRATCH_PATH="$2"; shift 2 ;;
        --skip-icon)      SKIP_ICON=true; shift ;;
        --skip-build)     SKIP_BUILD=true; shift ;;
        --help|-h)        usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# Validate version.
if ! validate_version "$VERSION"; then
    exit 1
fi

# Validate output path (if explicitly provided).
if [[ "${OUTPUT_DIR_ARG+x}" == "x" ]]; then
    if ! validate_output_path "$OUTPUT_DIR_ARG"; then
        exit 1
    fi
else
    validate_output_path "$OUTPUT_DIR"
fi

# Validate scratch path (if explicitly provided).
if [[ -n "${SCRATCH_PATH:-}" ]]; then
    if ! validate_scratch_path "$SCRATCH_PATH"; then
        exit 1
    fi
fi

# Validate notarize prerequisites.
if [[ "$NOTARIZE" == true && -z "$SIGN_IDENTITY" ]]; then
    echo "--notarize requires --sign with a Developer ID Application identity." >&2
    exit 1
fi
if [[ "$NOTARIZE" == true && -z "$NOTARY_PROFILE" ]]; then
    echo "--notarize requires --notary-profile (a notarytool keychain profile)." >&2
    exit 1
fi

cd "$PROJECT_DIR"
echo "=== Building $APP_NAME $VERSION (release) ==="
echo "  Output: $OUTPUT_DIR"
echo "  Project: $PROJECT_DIR"

# ---------------------------------------------------------------------------
# Step 1: Swift release build
# ---------------------------------------------------------------------------
BIN_DIR=""
BINARY=""
if [[ "$SKIP_BUILD" == true ]]; then
    echo "=== Skipping swift build (--skip-build) ==="
    # Try to find an existing release binary.
    if [[ -n "$SCRATCH_PATH" ]]; then
        BIN_DIR="$(swift build -c release --scratch-path "$SCRATCH_PATH" --show-bin-path)"
    else
        BIN_DIR="$(swift build -c release --show-bin-path)"
    fi
    BINARY="$BIN_DIR/ParallaxApp"
    if [[ ! -x "$BINARY" ]]; then
        echo "ERROR: --skip-build but no release binary found at $BINARY" >&2
        exit 1
    fi
else
    # macOS ships Bash 3.2. Under set -u, expanding an empty array through
    # "${array[@]}" can be treated as an unbound variable, so keep the optional
    # sandbox flag in explicit branches instead of an argument array.
    if [[ -n "$SCRATCH_PATH" ]]; then
        echo "  Scratch path: $SCRATCH_PATH"
        if [[ "${PARALLAX_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
            swift build --disable-sandbox -c release -j 2 --product ParallaxApp \
                --scratch-path "$SCRATCH_PATH"
            BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path \
                --scratch-path "$SCRATCH_PATH")"
        else
            swift build -c release -j 2 --product ParallaxApp \
                --scratch-path "$SCRATCH_PATH"
            BIN_DIR="$(swift build -c release --show-bin-path \
                --scratch-path "$SCRATCH_PATH")"
        fi
    else
        if [[ "${PARALLAX_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
            swift build --disable-sandbox -c release -j 2 --product ParallaxApp
            BIN_DIR="$(swift build --disable-sandbox -c release --show-bin-path)"
        else
            swift build -c release -j 2 --product ParallaxApp
            BIN_DIR="$(swift build -c release --show-bin-path)"
        fi
    fi
    BINARY="$BIN_DIR/ParallaxApp"
    if [[ ! -x "$BINARY" ]]; then
        echo "ERROR: release executable not found at: $BINARY" >&2
        exit 1
    fi
fi
echo "  Binary: $BINARY"

# ---------------------------------------------------------------------------
# Step 2: Generate app icon (original geometric, no copyrighted assets)
# ---------------------------------------------------------------------------
ICON_ICNS="$PROJECT_DIR/Scripts/AppIcon.icns"
if [[ "$SKIP_ICON" != true ]]; then
    echo "=== Generating app icon ==="
    if swift "$PROJECT_DIR/Scripts/generate-icon.swift" \
            --output "$PROJECT_DIR/Scripts/AppIcon.appiconset" 2>&1; then
        # Assemble .icns from the .iconset (iconutil needs .iconset naming).
        rm -rf "$PROJECT_DIR/Scripts/AppIcon.iconset"
        cp -R "$PROJECT_DIR/Scripts/AppIcon.appiconset" "$PROJECT_DIR/Scripts/AppIcon.iconset"
        if ! iconutil -c icns "$PROJECT_DIR/Scripts/AppIcon.iconset" \
                       -o "$ICON_ICNS" 2>&1; then
            echo "WARNING: iconutil failed; bundle will have no custom icon." >&2
            ICON_ICNS=""
        fi
    else
        echo "WARNING: icon generation failed; bundle will have no custom icon." >&2
        ICON_ICNS=""
    fi
fi

# ---------------------------------------------------------------------------
# Step 3: Prepare staging and output paths
# ---------------------------------------------------------------------------
# Atomic publish model: assemble + verify in a temp staging directory, then
# move the verified bundle into the final output location only on success.
# If any step fails, the staging dir is cleaned up and the existing output
# is untouched. Backups of previous outputs are made only at publish time
# and restored if the publish move fails.
mkdir -p "$OUTPUT_DIR"
FINAL_APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"
FINAL_DMG_PATH="$OUTPUT_DIR/$APP_NAME-$VERSION.dmg"

STAGING_ROOT="$(mktemp -d "$OUTPUT_DIR/.parallax-build.XXXXXX")"
APP_BUNDLE="$STAGING_ROOT/$APP_NAME.app"
DMG_PATH="$STAGING_ROOT/$APP_NAME-$VERSION.dmg"
DMG_STAGING="$STAGING_ROOT/dmg-staging"

# Track backup paths so the trap can restore them if the publish move fails.
BACKUP_APP=""
BACKUP_DMG=""
PUBLISHED=false

cleanup_and_maybe_restore() {
    local rc=$?
    # If we started publishing but didn't finish, restore backups so the
    # user's output directory isn't left empty or half-written.
    if [[ "$PUBLISHED" != true ]]; then
        if [[ -n "$BACKUP_APP" && -e "$BACKUP_APP" && ! -e "$FINAL_APP_BUNDLE" ]]; then
            mv "$BACKUP_APP" "$FINAL_APP_BUNDLE" 2>/dev/null || true
            echo "  Restored previous app bundle from backup." >&2
        fi
        if [[ -n "$BACKUP_DMG" && -e "$BACKUP_DMG" && ! -e "$FINAL_DMG_PATH" ]]; then
            mv "$BACKUP_DMG" "$FINAL_DMG_PATH" 2>/dev/null || true
            echo "  Restored previous DMG from backup." >&2
        fi
    fi
    rm -rf "$STAGING_ROOT"
    exit $rc
}
trap cleanup_and_maybe_restore EXIT

# ---------------------------------------------------------------------------
# Step 4: Assemble .app bundle (in staging)
# ---------------------------------------------------------------------------
echo "=== Assembling app bundle (staging: $STAGING_ROOT) ==="
mkdir -p "$APP_BUNDLE/Contents/MacOS" \
         "$APP_BUNDLE/Contents/Resources" \
         "$APP_BUNDLE/Contents/Frameworks"

# 4a. Main executable.
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/ParallaxApp"
chmod +x "$APP_BUNDLE/Contents/MacOS/ParallaxApp"

# 4b. Info.plist with version stamping and icon metadata.
cp "$PROJECT_DIR/Scripts/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" \
    "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" \
    "$APP_BUNDLE/Contents/Info.plist"

# 4c. App icon + icon metadata in Info.plist.
if [[ -n "$ICON_ICNS" && -f "$ICON_ICNS" ]]; then
    cp "$ICON_ICNS" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile AppIcon" \
        "$APP_BUNDLE/Contents/Info.plist"
    # CFBundleIconName — asset catalog name (used by modern macOS).
    /usr/libexec/PlistBuddy -c "Set :CFBundleIconName AppIcon" \
        "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    # Provenance: record that the icon is an original geometric asset,
    # not derived from copyrighted material. Stored as a custom key.
    /usr/libexec/PlistBuddy -c "Add :ParallaxIconSource string original-geometric" \
        "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c \
        "Add :ParallaxIconGenerator string Scripts/generate-icon.swift" \
        "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true
fi

# 4d. Meaningful resource copies — game content, not dummy filler.
#     These are real, authored documents the player can access in-app or
#     via Finder. No inflated duplicate media.
RESOURCES_DIR="$APP_BUNDLE/Contents/Resources"
mkdir -p "$RESOURCES_DIR/docs"

# Rulebook — the formal game rules.
if [[ -f "$PROJECT_DIR/docs/rulebook.md" ]]; then
    cp "$PROJECT_DIR/docs/rulebook.md" "$RESOURCES_DIR/docs/rulebook.md"
fi
# Licensing and attribution — IP-safe release boundary.
if [[ -f "$PROJECT_DIR/docs/licensing-and-attribution.md" ]]; then
    cp "$PROJECT_DIR/docs/licensing-and-attribution.md" \
       "$RESOURCES_DIR/docs/licensing-and-attribution.md"
fi
# Release packaging notes.
if [[ -f "$PROJECT_DIR/docs/release-packaging.md" ]]; then
    cp "$PROJECT_DIR/docs/release-packaging.md" \
       "$RESOURCES_DIR/docs/release-packaging.md"
fi
# README as a bundled quick-start.
if [[ -f "$PROJECT_DIR/README.md" ]]; then
    cp "$PROJECT_DIR/README.md" "$RESOURCES_DIR/README.md"
fi

# 4e. Swift runtime libraries (no-op when the OS already provides them).
if xcrun --find swift-stdlib-tool >/dev/null 2>&1; then
    xcrun swift-stdlib-tool --copy --platform macosx \
        --scan-executable "$APP_BUNDLE/Contents/MacOS/ParallaxApp" \
        --destination "$APP_BUNDLE/Contents/Frameworks" 2>&1 || true
fi

# 4f. SPM resource bundles — copy any *.bundle produced by SwiftPM
#     (from Bundle.module / resources: in Package.swift) into the app's
#     Resources directory. Currently none exist, but this handles future
#     resource additions by other agents without script changes.
if [[ -d "$BIN_DIR" ]]; then
    bundle_count=0
    for bndl in "$BIN_DIR"/*.bundle; do
        [[ -e "$bndl" ]] || continue
        cp -R "$bndl" "$RESOURCES_DIR/"
        bundle_count=$((bundle_count + 1))
    done
    if [[ "$bundle_count" -gt 0 ]]; then
        echo "  Copied $bundle_count SPM resource bundle(s) into Resources."
    fi
fi

# ---------------------------------------------------------------------------
# Step 5: Content manifest — SHA-256 hashes and byte sizes for every
#          bundled file. Generated BEFORE signing so the signature seals
#          the manifest along with all other content. The manifest documents
#          content files; it excludes itself and the _CodeSignature directory
#          (signature artifacts added during signing).
# ---------------------------------------------------------------------------
MANIFEST="$RESOURCES_DIR/content-manifest.txt"
echo "=== Generating content manifest ==="
{
    echo "# $APP_NAME content manifest"
    echo "# Version: $VERSION"
    echo "# Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Format: sha256  size  relative-path"
    echo "# The executable and code signature are verified separately by codesign."
    echo ""
    # Walk the bundle contents. Skip the manifest itself (not yet written)
    # and any _CodeSignature directory (not yet present — added by signing).
    cd "$APP_BUNDLE"
    find . -type f \
        ! -path "./Contents/MacOS/ParallaxApp" \
        ! -path "./Contents/Resources/content-manifest.txt" \
        ! -path "./Contents/_CodeSignature/*" \
        | sort | while IFS= read -r f; do
        rel="${f#./}"
        sha="$(file_sha256 "$f")"
        sz="$(file_size "$f")"
        printf '%s  %s  %s\n' "$sha" "$sz" "$rel"
    done
    cd "$PROJECT_DIR"
} > "$MANIFEST"
echo "  Manifest: $MANIFEST ($(file_size "$MANIFEST") bytes, $(grep -c '  ' "$MANIFEST") files)"

# ---------------------------------------------------------------------------
# Step 6: Code signing — seals the bundle including the manifest. Done
#         AFTER manifest generation so the signature covers all content.
# ---------------------------------------------------------------------------
if [[ -n "$SIGN_IDENTITY" ]]; then
    echo "=== Signing with $SIGN_IDENTITY ==="
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$PROJECT_DIR/Scripts/Parallax.entitlements" "$APP_BUNDLE"
else
    echo "=== Ad-hoc signing developer build ==="
    codesign --force --sign - "$APP_BUNDLE"
fi

# ---------------------------------------------------------------------------
# Step 7: Bundle verification (in staging — nothing touches final output yet)
# ---------------------------------------------------------------------------
echo "=== Verifying bundle (staging) ==="
if ! codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1; then
    echo "ERROR: codesign verification failed." >&2
    exit 1
fi

# Verify required bundle structure.
for required in \
    "Contents/MacOS/ParallaxApp" \
    "Contents/Info.plist" \
    "Contents/Resources/content-manifest.txt"; do
    if [[ ! -f "$APP_BUNDLE/$required" ]]; then
        echo "ERROR: missing required bundle file: $required" >&2
        exit 1
    fi
done

# Verify the executable is runnable.
if [[ ! -x "$APP_BUNDLE/Contents/MacOS/ParallaxApp" ]]; then
    echo "ERROR: bundle executable is not runnable." >&2
    exit 1
fi

# Verify manifest integrity — re-hash every file and compare.
# NOTE: The main executable (Contents/MacOS/ParallaxApp) is excluded from
# the hash comparison because code signing embeds the signature into the
# Mach-O binary, changing its hash after the manifest was generated. The
# executable's integrity is verified by codesign --verify above, which
# checks the embedded code signature and designated requirement.
echo "  Checking manifest integrity..."
manifest_errors=0
cd "$APP_BUNDLE"
while IFS= read -r line; do
    # Skip comments and blank lines.
    case "$line" in ''|'#'*) continue ;; esac
    expected_sha="$(echo "$line" | awk '{print $1}')"
    rel_path="$(echo "$line" | awk '{print $3}')"
    if [[ -z "$rel_path" || "$rel_path" == "Contents/Resources/content-manifest.txt" ]]; then
        continue
    fi
    # Skip the main executable — signing modifies its hash. Integrity is
    # guaranteed by the code signature (verified above).
    if [[ "$rel_path" == "Contents/MacOS/ParallaxApp" ]]; then
        continue
    fi
    if [[ ! -f "$rel_path" ]]; then
        echo "  MISSING: $rel_path" >&2
        manifest_errors=$((manifest_errors + 1))
        continue
    fi
    actual_sha="$(file_sha256 "$rel_path")"
    if [[ "$actual_sha" != "$expected_sha" ]]; then
        echo "  HASH MISMATCH: $rel_path (expected $expected_sha, got $actual_sha)" >&2
        manifest_errors=$((manifest_errors + 1))
    fi
done < "$MANIFEST"
cd "$PROJECT_DIR"
if [[ "$manifest_errors" -gt 0 ]]; then
    echo "ERROR: $manifest_errors manifest verification error(s)." >&2
    exit 1
fi
echo "  Manifest integrity: OK"

# ---------------------------------------------------------------------------
# Step 8: DMG creation (drag-to-Applications, in staging)
# ---------------------------------------------------------------------------
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"

echo "=== Creating drag-to-Applications DMG (staging) ==="
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" \
    -format UDZO -ov "$DMG_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null
echo "  DMG: $DMG_PATH ($(file_size "$DMG_PATH") bytes)"

# ---------------------------------------------------------------------------
# Step 9: Notarization (optional, before publish so a failed notarization
#         doesn't replace the working previous build)
# ---------------------------------------------------------------------------
if [[ "$NOTARIZE" == true ]]; then
    echo "=== Notarizing ==="
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
fi

# ---------------------------------------------------------------------------
# Step 10: Atomic publish — back up previous outputs, then move verified
#          staging artifacts into the final output location. Only reached
#          after all verification passes.
# ---------------------------------------------------------------------------
echo "=== Publishing verified build to $OUTPUT_DIR ==="
echo "  Recovering previous outputs..."
recoverable_backup "$FINAL_APP_BUNDLE"
BACKUP_APP="$LAST_BACKUP"
recoverable_backup "$FINAL_DMG_PATH"
BACKUP_DMG="$LAST_BACKUP"

# Move the verified app bundle into place.
mv "$APP_BUNDLE" "$FINAL_APP_BUNDLE"
APP_BUNDLE="$FINAL_APP_BUNDLE"
MANIFEST="$APP_BUNDLE/Contents/Resources/content-manifest.txt"

# Move the verified DMG into place.
mv "$DMG_PATH" "$FINAL_DMG_PATH"
DMG_PATH="$FINAL_DMG_PATH"

# Mark as published so the trap knows not to restore backups.
PUBLISHED=true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== Build complete ==="
echo "App:      $APP_BUNDLE"
echo "DMG:      $DMG_PATH"
echo "Manifest: $MANIFEST"
echo "Size:     app=$(file_size "$APP_BUNDLE/Contents/MacOS/ParallaxApp") bytes executable"
if [[ -z "$SIGN_IDENTITY" ]]; then
    echo "Status:   ad-hoc signed only; use --sign and --notarize for public distribution."
fi
