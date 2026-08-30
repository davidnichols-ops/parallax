# Release Packaging

Parallax ships as a native macOS `.app` bundle inside a drag-to-Install DMG.
The build pipeline lives in `Scripts/` and uses only standard installed tools:
Swift Package Manager, `codesign`, `iconutil`, `hdiutil`, `shasum`, and
`PlistBuddy`. No third-party packaging dependencies.

## Quick start

```bash
# Ad-hoc signed developer build (default):
./Scripts/build-release.sh

# Versioned build to a custom output directory:
./Scripts/build-release.sh --version 1.2.0 --output ./dist

# Public distribution (requires Apple Developer ID):
./Scripts/build-release.sh \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    --notarize --notary-profile "your-notary-profile"
```

## What the build produces

| Artifact | Path | Description |
| --- | --- | --- |
| `.app` bundle | `dist/Parallax.app` | Signed macOS app with icon, docs, manifest |
| `.dmg` | `dist/Parallax-<version>.dmg` | Drag-to-Applications disk image |
| Content manifest | `Contents/Resources/content-manifest.txt` | SHA-256 + size for every bundled file |
| App icon | `Contents/Resources/AppIcon.icns` | Original geometric holographic-board motif |

## Build script features

### Safe Bash 3.2

The build script targets macOS system Bash 3.2 (`/bin/bash`). It avoids
associative arrays, `read -N`, and other Bash 4+ features. All optional
flags use explicit branches rather than array expansion (which breaks under
`set -u` in Bash 3.2).

### Version and path validation

- `--version` must match `MAJOR.MINOR.PATCH` with optional pre-release
  suffix. Non-numeric, empty, or shell-metacharacter versions are rejected
  before any build step runs.
- `--output` is validated for safety: rejects root (`/`), path traversal
  (`..`), broad/home paths (`$HOME`, `/Users/david`, project root), and
  unwritable parent directories. Output must be a dedicated subdirectory.
- `--scratch-path` is validated similarly: must be absolute, not root/home/
  project/broad, no traversal.
- Missing option arguments (e.g. `--output` with no value) produce a clear
  error and exit 2, not a `set -u` unbound variable crash.

### Atomic staging and publish

The build assembles and verifies the entire `.app` bundle and DMG in a
temporary staging directory (`mktemp -d`). Only after all verification
passes (structure, codesign, manifest integrity) does the script:

1. Back up any previous output to `<name>.backup-YYYYMMDD-HHMMSS`
2. Atomically move the verified staging artifacts into the output directory

If any step fails before publish, the staging directory is cleaned up and
the existing output is left untouched. If the publish move itself fails,
the trap handler restores the most recent backup automatically.

### Recoverable previous outputs

Previous `.app` and `.dmg` artifacts are never deleted. They are moved to
`<name>.backup-YYYYMMDD-HHMMSS` before the new build publishes. This means
you can always roll back to the last working build without re-running the
compiler. Backups are restored automatically if the publish step fails.

### App bundle resource copies

The bundle includes meaningful game content in `Contents/Resources/`:

| Resource | Source | Purpose |
| --- | --- | --- |
| `docs/rulebook.md` | `docs/rulebook.md` | Formal game rules |
| `docs/licensing-and-attribution.md` | `docs/licensing-and-attribution.md` | IP-safe release boundary |
| `docs/release-packaging.md` | `docs/release-packaging.md` | This document |
| `README.md` | `README.md` | Quick-start and architecture overview |
| `AppIcon.icns` | `Scripts/generate-icon.swift` | Original geometric icon |
| `content-manifest.txt` | Generated at build time | Integrity record |
| `*.bundle` | SPM build output | Resource bundles from `Bundle.module` (if declared) |

No dummy media, no inflated duplicate files, no filler bytes. Every resource
is real, authored content.

### Content manifest

`content-manifest.txt` records the SHA-256 hash and byte size of every file
in the bundle. The build script verifies this manifest after assembly — if
any file's hash doesn't match, the build fails. Use
`Scripts/verify-bundle.sh` to re-check a bundle at any time:

```bash
./Scripts/verify-bundle.sh dist/Parallax.app
```

### App icon generation

`Scripts/generate-icon.swift` draws an original geometric icon using
CoreGraphics/AppKit — no copyrighted or franchise imagery. The motif
echoes the holographic board aesthetic: layered translucent planes
(lavender, chartreuse, yellow), nesting green/teal outlines, and a small
ring token. The script produces a complete `.appiconset` and `iconutil`
assembles the `.icns`.

```bash
# Regenerate just the icon:
swift Scripts/generate-icon.swift --output Scripts/AppIcon.appiconset
cp -R Scripts/AppIcon.appiconset Scripts/AppIcon.iconset
iconutil -c icns Scripts/AppIcon.iconset -o Scripts/AppIcon.icns
```

### Concurrent build support

Use `--scratch-path` to give each build a unique SPM scratch directory,
preventing conflicts when multiple agents build simultaneously:

```bash
./Scripts/build-release.sh --scratch-path /private/tmp/parallax-release-build
```

## Verification

The build script performs three verification passes before declaring
success:

1. **Structure** — required files exist, executable is runnable, Info.plist
   has version stamps and icon metadata.
2. **Signature** — `codesign --verify --deep --strict` passes.
3. **Manifest integrity** — every content file's SHA-256 matches the
   manifest. The main executable is excluded from hash comparison (code
   signing modifies the Mach-O binary); its integrity is verified by the
   signature check.

If any check fails, the script exits non-zero with a diagnostic message.
The staging directory is cleaned up and no output is published.

### Test suite

`Scripts/test-build-release.sh` runs 39 tests covering:

- Bash syntax validation (`bash -n`)
- `--help` / `-h` output
- Missing option arguments (set -u crash regression)
- Invalid version strings
- Unsafe output and scratch paths
- Unknown options
- Full packaging run with `--skip-build` (uses existing release binary)
- `verify-bundle.sh` on the built bundle
- Info.plist icon metadata presence
- Content manifest entry count
- DMG creation
- Atomic publish (second build replaces first, old bundle backed up)

```bash
./Scripts/test-build-release.sh           # concise
./Scripts/test-build-release.sh --verbose # full output
```

## Signing and notarization

| Mode | Command | Result |
| --- | --- | --- |
| Ad-hoc | `./Scripts/build-release.sh` | Local developer testing |
| Developer ID | `--sign "Developer ID Application: …"` | Gatekeeper distribution |
| Notarized | `--sign … --notarize --notary-profile …` | Public distribution |

The entitlements file (`Scripts/Parallax.entitlements`) disables app sandbox
(network client/server enabled for future LAN play, audio input disabled).

For the full public-release checklist (Apple credential prerequisites,
notarytool setup, Universal 2 feasibility, Gatekeeper user-open instructions,
and repo handoff), see [release-readiness.md](release-readiness.md).

## SBOM (Software Bill of Materials)

`Scripts/generate-sbom.sh` produces a CycloneDX 1.5 JSON document covering
the package name, version, supplier, all SPM targets (components) with their
types and inter-target dependencies, the Swift toolchain version, and the
macOS deployment target. It confirms that no external package dependencies
are declared.

```bash
# Generate:
./Scripts/generate-sbom.sh --version 2.1.0-rc4 --output ./dist/parallax-sbom.json

# Validate:
./Scripts/generate-sbom.sh --validate ./dist/parallax-sbom.json
```

The SBOM is a component/dependency inventory. The content manifest
(`Contents/Resources/content-manifest.txt`) remains the integrity inventory
for bundled files. They are complementary — see
[release-readiness.md](release-readiness.md) for the distinction.

## File ownership (release agent)

| Path | Owner |
| --- | --- |
| `Scripts/build-release.sh` | release |
| `Scripts/verify-bundle.sh` | release |
| `Scripts/test-build-release.sh` | release |
| `Scripts/generate-sbom.sh` | release |
| `Scripts/generate-icon.swift` | release |
| `Scripts/Info.plist` | release |
| `Scripts/Parallax.entitlements` | release |
| `Scripts/AppIcon.*` | release (generated) |
| `docs/release-packaging.md` | release |
| `docs/release-readiness.md` | release |
| `docs/content-manifest.md` | release |
| `.github/workflows/ci.yml` | release |
| `.gitignore` | release |
| `README.md` | release |

The release agent does not modify `Package.swift`, `Sources/`, or `Tests/`.
The main coordinator controls Package.swift resource hooks and invokes the
final build after integration.
